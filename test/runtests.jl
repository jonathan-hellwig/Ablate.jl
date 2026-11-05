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

    @testset "Scientific Hygiene, JIT Retry, @verify, Phases & Code Diff" begin
        mktempdir() do tmp
            run(Cmd(`git init -q`, dir=tmp))
            run(Cmd(`git config user.email "test@example.com"`, dir=tmp))
            run(Cmd(`git config user.name "Tester"`, dir=tmp))
            mkpath(joinpath(tmp, "src"))
            solver_file = joinpath(tmp, "src", "solver.jl")
            write(solver_file, "solve(x) = x + 1\n")
            run(Cmd(`git add .`, dir=tmp))
            run(Cmd(`git commit -q -m "initial"`, dir=tmp))

            # Run #1: Clean baseline
            @ablate "baseline_v1" suite="bench_suite" dir=tmp quiet=true begin
                @case "prob_1" begin
                    @phase :preprocess sleep(0.002)
                    @count :iterations 5
                    @metric :depth 2
                    ok_v = @verify (1 + 1 == 2)
                    log_result!(ok=ok_v)
                end
                @case "prob_grouped" begin
                    raw_p = Dict(:step2 => 1.0, :step4 => 3.0, :reduce_1 => 2.0)
                    log_result!(ok=true, verified=true, phases=raw_p, phase_unit=:ms, group_phases=true, rank=2)
                end
            end

            # Modify src/solver.jl without committing
            write(solver_file, "solve(x) = x + 2 # dirty ablation tweak\n")

            # Run #2: Dirty working tree with simulated regression on prob_1
            @ablate "dirty_ablation_v2" suite="bench_suite" dir=tmp auto_compare=false quiet=true begin
                @case "prob_1" begin
                    @phase :preprocess sleep(0.015)
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
            @test !isempty(runs[2]["patch_hash"])

            # Verify generic numbered phase grouping on Run #1
            cases_1 = Ablate.load_cases(joinpath(tmp, ".ablation"), 1)
            c_grp = cases_1[2]
            @test c_grp["metrics"]["rank"] == 2
            @test c_grp["phases"]["step"] ≈ 0.004
            @test c_grp["phases"]["reduce"] ≈ 0.002

            # Verify regression detection & attribution between Run #1 and Run #2
            regs = Ablate.regressions(2; against=1, dir=tmp, min_delta_s=0.005)
            @test length(regs) == 1
            @test regs[1][1] == "prob_1"
            @test occursin("depth:2->4", regs[1][5])
            @test occursin("PHASE:preprocess", regs[1][5])
            @test occursin("iterations:5->42", regs[1][5])

            # Verify code diff between clean Run #1 and dirty Run #2
            diff_out = Ablate.code_diff(1, 2; dir=tmp)
            @test occursin("-solve(x) = x + 1", diff_out)
            @test occursin("+solve(x) = x + 2 # dirty ablation tweak", diff_out)

            # Revert working tree and restore patch from Run #2
            write(solver_file, "solve(x) = x + 1\n")
            @test Ablate.restore!(2; dir=tmp, dry_run=true) == true
            @test Ablate.restore!(2; dir=tmp, dry_run=false) == true
            @test occursin("dirty ablation tweak", read(solver_file, String))
        end
    end
end
