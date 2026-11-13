using Test
using Ablate

@testset "Ablate.jl General-Purpose Unit Tests" begin
    @testset "JSON Encoder & Parser Roundtrip" begin
        d = Dict{String,Any}(
            "run_id" => 1,
            "label" => "test \"quotes\" and \n newlines",
            "ok" => true,
            "failed" => false,
            "nothing_val" => nothing,
            "float_val" => 0.125,
            "arr" => Any[1, 2, "three", Dict{String,Any}("k" => 42)]
        )
        s = Ablate.to_json(d)
        parsed = Ablate.parse_json(s)
        @test parsed["run_id"] == 1
        @test parsed["label"] == "test \"quotes\" and \n newlines"
        @test parsed["ok"] === true
        @test parsed["failed"] === false
        @test parsed["nothing_val"] === nothing
        @test parsed["float_val"] ≈ 0.125
        @test parsed["arr"][4]["k"] == 42
    end

    @testset "5 Scientific Guardrails, Plots, Remote Import & Code Diff" begin
        mktempdir() do tmp
            run(Cmd(`git init -q`, dir=tmp))
            run(Cmd(`git config user.email "test@example.com"`, dir=tmp))
            run(Cmd(`git config user.name "Tester"`, dir=tmp))
            mkpath(joinpath(tmp, "src"))
            solver_file = joinpath(tmp, "src", "solver.jl")
            write(solver_file, "solve(x) = x + 1\n")
            run(Cmd(`git add .`, dir=tmp))
            run(Cmd(`git commit -q -m "initial"`, dir=tmp))

            # Run #1: Clean baseline with @verify and fast case triggering micro-sampling
            @ablate "baseline_v1" suite="bench_suite" timeout_s=1.0 dir=tmp quiet=true begin
                @case "prob_1" begin
                    @phase :preprocess sleep(0.002)
                    @count :iterations 5
                    @metric :depth 2
                    ok_v = @verify (1 + 1 == 2)
                    log_result!(ok=ok_v)
                end
                @case "prob_grouped" begin
                    raw_p = Dict(:step2 => 1.0, :step4 => 3.0, :reduce_1 => 2.0)
                    # Intentionally omit @verify to test UNVERIFIED_OK status
                    log_result!(ok=true, phases=raw_p, phase_unit=:ms, group_phases=true, rank=2)
                end
            end

            # Modify src/solver.jl without committing
            write(solver_file, "solve(x) = x + 2 # dirty ablation tweak\n")

            # Run #2: Dirty working tree with simulated regression on prob_1
            @ablate "dirty_ablation_v2" suite="bench_suite" timeout_s=1.0 dir=tmp auto_compare=false quiet=true begin
                @case "prob_1" begin
                    @phase :preprocess sleep(0.018)
                    @count :iterations 42
                    @metric :depth 4
                    ok_v = @verify (2 + 2 == 4)
                    log_result!(ok=ok_v)
                end
                @case "prob_grouped" begin
                    raw_p = Dict(:step2 => 1.0, :step4 => 3.0, :reduce_1 => 2.0)
                    log_result!(ok=true, verified=true, phases=raw_p, phase_unit=:ms, group_phases=true, rank=2)
                end
            end

            runs = Ablate.history(suite="bench_suite", dir=tmp)
            @test length(runs) == 2
            @test runs[1]["git_dirty"] == false
            @test runs[2]["git_dirty"] == true
            @test runs[1]["suite_hash"] == runs[2]["suite_hash"]
            @test haskey(runs[1]["env_info"], "cpu_model")
            @test haskey(runs[1], "par2_score")
            @test runs[1]["n_verified"] == 1
            @test runs[1]["n_unverified_ok"] == 1
            @test runs[2]["n_verified"] == 2

            # Verify adaptive micro-sampling ran on fast prob_1 in Run #1
            cases_1 = Ablate.load_cases(joinpath(tmp, ".ablation"), 1)
            @test cases_1[1]["status"] == "VERIFIED"
            @test cases_1[1]["samples"] >= 2
            @test cases_1[2]["status"] == "UNVERIFIED_OK"

            # Verify regression detection & attribution between Run #1 and Run #2
            regs = Ablate.regressions(2; against=1, dir=tmp, min_delta_s=0.005)
            @test length(regs) == 1
            @test regs[1][1] == "prob_1"
            @test occursin("depth:2->4", regs[1][5])
            @test occursin("PHASE:preprocess", regs[1][5])
            @test occursin("iterations:5->42", regs[1][5])

            # Test SVG plot generation
            cactus_svg = Ablate.plot_cactus([1, 2]; dir=tmp)
            scatter_svg = Ablate.plot_scatter(1, 2; dir=tmp)
            @test isfile(cactus_svg)
            @test isfile(scatter_svg)

            # Verify code diff between clean Run #1 and dirty Run #2
            diff_out = Ablate.code_diff(1, 2; dir=tmp)
            @test occursin("-solve(x) = x + 1", diff_out)
            @test occursin("+solve(x) = x + 2 # dirty ablation tweak", diff_out)

            # Test BenchmarkLog, checkpoint!, phase_breakdown, and explain
            b = BenchmarkLog()
            checkpoint!(b, :step, 2)
            checkpoint!(b, :step, 4)
            @test haskey(b, :step2)
            @test haskey(b, :step4)

            @ablate "run3_benchlog" suite="unit" dir=tmp auto_compare=false quiet=true begin
                @case "prob_1" begin
                    bl = BenchmarkLog()
                    checkpoint!(bl, :gb, 2)
                    checkpoint!(bl, :gb, 4)
                    @verify true
                    log_result!(bl; rank=1)
                end
            end
            ex = explain("prob_1", 1, 3; dir=tmp)
            @test ex.new["metrics"]["max_step"] == 4
            @test ex.new["counters"]["calls_gb"] == 2
            phase_breakdown(1, 3; dir=tmp)

            # Revert working tree and restore patch from Run #2
            write(solver_file, "solve(x) = x + 1\n")
            @test Ablate.restore!(2; dir=tmp, dry_run=true) == true
            @test Ablate.restore!(2; dir=tmp, dry_run=false) == true
            @test occursin("dirty ablation tweak", read(solver_file, String))
        end
    end

    @testset "Dataset Manifests, Checksums & Split Guardrails" begin
        mktempdir() do tmp
            run(Cmd(`git init -q`, dir=tmp))
            run(Cmd(`git config user.email "test@example.com"`, dir=tmp))
            run(Cmd(`git config user.name "Tester"`, dir=tmp))

            bdir = joinpath(tmp, "bench")
            for fam in ("famA", "famB")
                mkpath(joinpath(bdir, fam))
                for i in 1:5
                    write(joinpath(bdir, fam, "p$i.smt2"), "(assert (= x $i))\n")
                end
            end

            manifest = create_manifest(bdir; name="toy", version="1.0.0", train_fraction=0.2, seed=42)
            @test isfile(manifest)

            ds_train = load_dataset(manifest; split="train")
            ds_test = load_dataset(manifest; split="test")
            @test length(ds_train.files) == 2
            @test length(ds_test.files) == 8
            @test isempty(intersect(Set(ds_train.relpaths), Set(ds_test.relpaths)))
            @test ds_train.suite == "toy@1.0.0:train"
            @test ds_test.suite == "toy@1.0.0:test"

            ds_fam = load_dataset(manifest; split="test", family="famA")
            @test length(ds_fam.files) == 4
            @test all(r -> startswith(r, "famA/"), ds_fam.relpaths)

            @test assert_train_split(ds_train) == true
            @test_throws ErrorException assert_train_split(ds_test)
            @test assert_train_split(ds_test; allow_test_leakage=true) == true

            # Tampering detection
            write(ds_test.files[1], "(assert false)\n")
            @test_throws ErrorException load_dataset(manifest; split="test")

            # Cross-split compare/plot guard
            @ablate "r_train" suite=ds_train.suite split=ds_train.split dir=tmp auto_compare=false quiet=true begin
                @case "c1" begin
                    @verify true
                    log_result!(ok=true)
                end
            end
            @ablate "r_test" suite=ds_test.suite split=ds_test.split dir=tmp auto_compare=false quiet=true begin
                @case "c1" begin
                    @verify true
                    log_result!(ok=true)
                end
            end
            @test_throws ErrorException compare(1, 2; dir=tmp)
            @test_throws ErrorException plot_cactus([1, 2]; dir=tmp)
            @test_throws ErrorException plot_phases([1, 2]; dir=tmp)
        end
    end
end
