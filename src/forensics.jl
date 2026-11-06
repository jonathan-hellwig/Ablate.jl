# ==============================================================================
# src/forensics.jl — Copy-Paste Function Diffing, Suite Phase Breakdown & Outlier Forensics
# ==============================================================================

"""
    fn_source(f::Function; normalize_name::Bool=false, follow_wrapper::Bool=true) -> String

Extracts the complete Julia source code block(s) of function `f` from its defining file(s)
using `methods(f)` and `Meta.parse`.
- If `follow_wrapper=true` and `f`'s main method is a thin wrapper delegating to another
  function in `parentmodule(f)` (e.g. `refute8` calling `refute7`), automatically includes
  the delegated function's source block as well.
- If `normalize_name=true`, replaces the function identifier with `TARGET_FN` so unified diffs
  between copy-pasted functions (`refute6` vs `refute8`) highlight only algorithmic differences.
"""
function fn_source(
    f::Function;
    normalize_name::Bool=false,
    follow_wrapper::Bool=true,
    _visited::Set{Symbol}=Set{Symbol}()
)::String
    fname = nameof(f)
    push!(_visited, fname)
    mod = parentmodule(f)

    locs = Tuple{String,Int}[]
    for m in methods(f)
        fl = String(m.file)
        ln = Int(m.line)
        if isfile(fl) && ln > 0 && !((fl, ln) in locs)
            push!(locs, (fl, ln))
        end
    end
    sort!(locs; by=x -> (x[1], x[2]))

    blocks = String[]
    delegated = Symbol[]

    for (fl, ln) in locs
        content = read(fl, String)
        lines = split(content, '\n')
        start_ln = clamp(ln, 1, length(lines))
        # Scan up to 8 lines back if m.line landed inside a multi-line signature or body start
        for back in 0:min(8, start_ln - 1)
            cand = start_ln - back
            s_line = lstrip(lines[cand])
            if startswith(s_line, "function ") || occursin(Regex("^$(fname)\\s*\\("), s_line)
                start_ln = cand
                break
            end
        end

        # Compute byte offset of start_ln
        byte_idx = 1
        for i in 1:(start_ln - 1)
            byte_idx += ncodeunits(lines[i]) + 1
        end

        try
            expr, next_idx = Meta.parse(content, byte_idx; greedy=true)
            end_idx = prevind(content, min(next_idx, lastindex(content) + 1))
            raw_block = strip(content[byte_idx:end_idx])
            push!(blocks, raw_block)
        catch
            # Fallback: grab 30 lines from start_ln
            stop_ln = min(length(lines), start_ln + 30)
            push!(blocks, join(lines[start_ln:stop_ln], "\n"))
        end
    end

    # Prefer `function ... end` blocks over short `f(...) = ...` dispatchers when selecting the primary method
    fn_blocks = filter(b -> startswith(lstrip(b), "function "), blocks)
    cand_blocks = isempty(fn_blocks) ? blocks : fn_blocks
    main_blk = isempty(cand_blocks) ? "" : argmax(ncodeunits, cand_blocks)
    if follow_wrapper && !isempty(main_blk) && count(==('\n'), main_blk) <= 6
        for m_call in eachmatch(r"\b([a-zA-Z_][a-zA-Z0-9_!]*)\s*\(", main_blk)
            callee = Symbol(m_call.captures[1])
            if !(callee in _visited) && callee != fname && !startswith(String(callee), "_dispatch") && isdefined(mod, callee)
                obj = getfield(mod, callee)
                if obj isa Function && parentmodule(obj) === mod
                    push!(delegated, callee)
                end
            end
        end
    end

    if follow_wrapper && !isempty(delegated)
        for callee in unique(delegated)
            callee_fn = getfield(mod, callee)
            sub_src = fn_source(callee_fn; normalize_name=normalize_name, follow_wrapper=true, _visited=_visited)
            if normalize_name
                return sub_src
            else
                push!(blocks, "# --- Delegated implementation: $(callee) ---\n" * sub_src)
            end
        end
    end

    if normalize_name && !isempty(cand_blocks)
        norm_blk = replace(main_blk, Regex("\\b$(fname)\\b") => "TARGET_FN")
        return norm_blk * "\n"
    end

    return join(blocks, "\n\n") * "\n"
end

function _print_colored_diff(diff_str::AbstractString, header::AbstractString)
    printstyled("═══ $header ═══\n"; bold=true, color=:cyan)
    if isempty(strip(diff_str))
        printstyled("  No code differences found.\n"; color=:green)
        return
    end
    for line in split(diff_str, '\n')
        if startswith(line, "---") || startswith(line, "+++") || startswith(line, "diff ") || startswith(line, "index ")
            continue
        elseif startswith(line, "+")
            printstyled("  ", line, "\n"; color=:green)
        elseif startswith(line, "-")
            printstyled("  ", line, "\n"; color=:red)
        elseif startswith(line, "@@")
            printstyled("  ", line, "\n"; color=:cyan)
        else
            println("  ", line)
        end
    end
    println(repeat("═", 90))
end

"""
    fn_diff(f_a::Function, f_b::Function; normalize_name::Bool=true) -> String

Directly diffs the Julia source implementations of two copy-pasted functions `f_a` and `f_b`
(even if they live in the same file at the same git commit, or if one is a thin wrapper like
`refute8 -> refute7`).
"""
function fn_diff(f_a::Function, f_b::Function; normalize_name::Bool=true)::String
    src_a = fn_source(f_a; normalize_name=normalize_name, follow_wrapper=true)
    src_b = fn_source(f_b; normalize_name=normalize_name, follow_wrapper=true)
    diff_str = mktempdir() do tmp
        fa = joinpath(tmp, "$(nameof(f_a)).jl")
        fb = joinpath(tmp, "$(nameof(f_b)).jl")
        write(fa, src_a)
        write(fb, src_b)
        _, out = _read_cmd_safe(Cmd(`git diff --no-index -U3 -- $(basename(fa)) $(basename(fb))`, dir=tmp))
        out
    end
    _print_colored_diff(diff_str, "Function Diff: $(nameof(f_a)) vs $(nameof(f_b))")
    return diff_str
end

function _snapshot_target_fn!(ab_dir::AbstractString, params::Dict{String,Any})
    fn_dir = joinpath(ab_dir, "functions")
    mkpath(fn_dir)
    for (k, v) in collect(params)
        if v isa Function
            raw_src = fn_source(v; normalize_name=false, follow_wrapper=true)
            norm_src = fn_source(v; normalize_name=true, follow_wrapper=true)
            h = bytes2hex(sha256(norm_src))[1:12]
            write(joinpath(fn_dir, "$(h).jl"), norm_src)
            write(joinpath(fn_dir, "$(h)_raw.jl"), raw_src)
            params[k] = string(nameof(v))
            params["_target_fn"] = string(nameof(v))
            params["_target_hash"] = h
        end
    end
end

function _print_side_by_side_benches(
    title_a::AbstractString,
    tot_a_ms::Float64,
    ph_a::AbstractDict,
    st_a::AbstractDict,
    title_b::AbstractString,
    tot_b_ms::Float64,
    ph_b::AbstractDict,
    st_b::AbstractDict;
    min_ms::Float64=0.005
)
    rows_a = [(String(k), Float64(v) * 1e3) for (k, v) in ph_a if Float64(v) * 1e3 >= min_ms]
    rows_b = [(String(k), Float64(v) * 1e3) for (k, v) in ph_b if Float64(v) * 1e3 >= min_ms]
    sort!(rows_a; by=x -> -x[2])
    sort!(rows_b; by=x -> -x[2])

    sum_a = max(tot_a_ms, sum(x[2] for x in rows_a; init=0.0), 1e-6)
    sum_b = max(tot_b_ms, sum(x[2] for x in rows_b; init=0.0), 1e-6)

    ta_s = length(title_a) > 48 ? first(title_a, 45) * "..." : title_a
    tb_s = length(title_b) > 48 ? first(title_b, 45) * "..." : title_b

    @printf("  %-48s │ %-48s\n", ta_s, tb_s)
    @printf("  %-22s %10s %7s %6s │ %-22s %10s %7s %6s\n",
        "Checkpoint", "Time(ms)", "%", "Steps", "Checkpoint", "Time(ms)", "%", "Steps")
    println("  " * repeat("─", 48) * "─┼─" * repeat("─", 48))

    n_rows = max(length(rows_a), length(rows_b))
    for i in 1:n_rows
        left_s = if i <= length(rows_a)
            k, v = rows_a[i]
            ks = length(k) > 22 ? first(k, 21) * "…" : k
            pct = 100.0 * v / sum_a
            st = get(st_a, "steps_" * k, 0)
            st_str = st > 0 ? string(st) : "-"
            @sprintf("%-22s %10.2f %6.1f%% %6s", ks, v, pct, st_str)
        else
            repeat(" ", 48)
        end

        right_s = if i <= length(rows_b)
            k, v = rows_b[i]
            ks = length(k) > 22 ? first(k, 21) * "…" : k
            pct = 100.0 * v / sum_b
            st = get(st_b, "steps_" * k, 0)
            st_str = st > 0 ? string(st) : "-"
            @sprintf("%-22s %10.2f %6.1f%% %6s", ks, v, pct, st_str)
        else
            ""
        end
        println("  ", left_s, " │ ", right_s)
    end
    println("  " * repeat("─", 48) * "─┴─" * repeat("─", 48))
    dt = tot_b_ms - tot_a_ms
    dpct = tot_a_ms > 0 ? 100.0 * dt / tot_a_ms : 0.0
    @printf("  %-22s %10.2f %7s %6s │ %-22s %10.2f  (%+.1f%%)\n",
        "Total Compute", tot_a_ms, "100.0%", "", "Total Compute", tot_b_ms, dpct)
end

"""
    phase_breakdown(run_a=:prev, run_b=:last; suite=nothing, dir=pwd())

Prints side-by-side aggregate `BenchmarkLog` profiles over all jointly solved cases between
`run_a` and `run_b`, ranked by each run's own phase share (`Time(ms)`, `%`, `Steps`).
"""
function phase_breakdown(
    run_a=:prev,
    run_b=:last;
    suite::Union{Nothing,AbstractString}=nothing,
    dir::AbstractString=pwd()
)
    repo_root = find_repo_root(dir)
    ab_dir = ensure_ablation_dirs(repo_root)
    runs = load_runs(ab_dir)
    id_b = _resolve_run_id(run_b, runs, ab_dir; suite=suite)
    rb = runs[findfirst(r -> Int(r["run_id"]) == id_b, runs)]
    target_suite = suite === nothing ? String(rb["suite"]) : String(suite)
    id_a = _resolve_run_id(run_a, runs, ab_dir; suite=target_suite)
    ra = runs[findfirst(r -> Int(r["run_id"]) == id_a, runs)]

    cases_a = Dict(String(c["name"]) => c for c in load_cases(ab_dir, id_a))
    cases_b = Dict(String(c["name"]) => c for c in load_cases(ab_dir, id_b))
    common = sort!(collect(intersect(keys(cases_a), keys(cases_b))))
    joint_ok = filter(n -> Bool(get(cases_a[n], "ok", true)) && Bool(get(cases_b[n], "ok", true)), common)

    tot_a = sum(Float64(get(cases_a[n], "time_compute", 0.0)) for n in joint_ok; init=0.0)
    tot_b = sum(Float64(get(cases_b[n], "time_compute", 0.0)) for n in joint_ok; init=0.0)

    ph_a = Dict{String,Float64}()
    ph_b = Dict{String,Float64}()
    st_a = Dict{String,Int64}()
    st_b = Dict{String,Int64}()

    for n in joint_ok
        ca, cb = cases_a[n], cases_b[n]
        for (k, v) in get(ca, "phases", Dict{String,Any}())
            ph_a[k] = get(ph_a, k, 0.0) + Float64(v)
        end
        for (k, v) in get(cb, "phases", Dict{String,Any}())
            ph_b[k] = get(ph_b, k, 0.0) + Float64(v)
        end
        for (k, v) in get(ca, "counters", Dict{String,Any}())
            st_a[k] = get(st_a, k, Int64(0)) + Int64(v)
        end
        for (k, v) in get(cb, "counters", Dict{String,Any}())
            st_b[k] = get(st_b, k, Int64(0)) + Int64(v)
        end
    end

    println(repeat("═", 104))
    printstyled(@sprintf("AGGREGATE BENCHMARK PROFILES: Run #%d vs Run #%d  [%d common solved]\n",
        id_a, id_b, length(joint_ok)); bold=true, color=:cyan)
    println(repeat("─", 104))
    _print_side_by_side_benches(
        "Ref (#$id_a): $(ra["label"])", tot_a * 1e3, ph_a, st_a,
        "New (#$id_b): $(rb["label"])", tot_b * 1e3, ph_b, st_b;
        min_ms=0.01
    )

    # Discrete metric shifts across common solved cases
    m_keys = sort!(collect(union(
        [keys(get(cases_a[n], "metrics", Dict{String,Any}())) for n in joint_ok]...,
        [keys(get(cases_b[n], "metrics", Dict{String,Any}())) for n in joint_ok]...
    )))
    if !isempty(m_keys)
        println(repeat("─", 104))
        printstyled("  Metric Shifts Across Common Cases:\n"; bold=true)
        for mk in m_keys
            lower, same, higher = 0, 0, 0
            for n in joint_ok
                va = get(get(cases_a[n], "metrics", Dict{String,Any}()), mk, nothing)
                vb = get(get(cases_b[n], "metrics", Dict{String,Any}()), mk, nothing)
                if va isa Real && vb isa Real
                    if vb < va
                        lower += 1
                    elseif vb > va
                        higher += 1
                    else
                        same += 1
                    end
                end
            end
            if lower + higher > 0
                println("    • $mk: decreased on $lower cases, unchanged on $same, increased on $higher")
            end
        end
    end
    println(repeat("═", 104))
    return nothing
end

"""
    explain(case_substr::AbstractString, run_a=:prev, run_b=:last; suite=nothing, dir=pwd())

Deep-dive forensics inspector for a specific benchmark outlier matching `case_substr`
between `run_a` and `run_b`. Prints side-by-side timing/GC/verify decomposition,
automated root-cause diagnosis, phase/step waterfall, and metric shifts.
"""
function explain(
    case_substr::AbstractString,
    run_a=:prev,
    run_b=:last;
    suite::Union{Nothing,AbstractString}=nothing,
    dir::AbstractString=pwd()
)
    repo_root = find_repo_root(dir)
    ab_dir = ensure_ablation_dirs(repo_root)
    runs = load_runs(ab_dir)
    id_b = _resolve_run_id(run_b, runs, ab_dir; suite=suite)
    rb = runs[findfirst(r -> Int(r["run_id"]) == id_b, runs)]
    target_suite = suite === nothing ? String(rb["suite"]) : String(suite)
    id_a = _resolve_run_id(run_a, runs, ab_dir; suite=target_suite)
    ra = runs[findfirst(r -> Int(r["run_id"]) == id_a, runs)]

    cases_a = load_cases(ab_dir, id_a)
    cases_b = load_cases(ab_dir, id_b)
    idx_a = findfirst(c -> occursin(case_substr, String(c["name"])), cases_a)
    idx_b = findfirst(c -> occursin(case_substr, String(c["name"])), cases_b)
    (idx_a === nothing || idx_b === nothing) && error("No case matching '$case_substr' found in both Run #$id_a and Run #$id_b")

    ca = cases_a[idx_a]
    cb = cases_b[idx_b]
    cname = String(ca["name"])

    ta = Float64(get(ca, "time_compute", 0.0)) * 1e3
    tb = Float64(get(cb, "time_compute", 0.0)) * 1e3
    wa = Float64(get(ca, "time_wall", 0.0)) * 1e3
    wb = Float64(get(cb, "time_wall", 0.0)) * 1e3
    ga = Float64(get(ca, "time_gc", 0.0)) * 1e3
    gb = Float64(get(cb, "time_gc", 0.0)) * 1e3
    va = Float64(get(ca, "time_verify", 0.0)) * 1e3
    vb = Float64(get(cb, "time_verify", 0.0)) * 1e3
    sa = Float64(get(ca, "time_spread", 0.0)) * 1e3
    sb = Float64(get(cb, "time_spread", 0.0)) * 1e3
    aa = Float64(get(ca, "alloc_bytes", 0)) / 1024.0
    ab = Float64(get(cb, "alloc_bytes", 0)) / 1024.0

    println(repeat("═", 104))
    printstyled("OUTLIER FORENSICS: $cname\n"; bold=true, color=:cyan)
    println("  Ref Run #$id_a: $(ra["label"]) ($(ra["code_signature"]))")
    println("  New Run #$id_b: $(rb["label"]) ($(rb["code_signature"]))")
    println(repeat("─", 104))

    # 1. Automated Root-Cause Verdict
    verdict = _attribute_cause(ca, cb)
    dt = tb - ta
    pct = ta > 0 ? 100.0 * dt / ta : 0.0
    v_col = dt < 0 ? :green : :red
    printstyled(@sprintf("  Verdict: %+.2f ms (%+.1f%%)  =>  %s\n", dt, pct, verdict); bold=true, color=v_col)
    if abs(dt) < max(sa, sb)
        printstyled(@sprintf("  ⚠ Note: Delta (%.2f ms) is smaller than empirical sample spread (%.2f ms) — likely runtime noise.\n",
            abs(dt), max(sa, sb)); color=:yellow)
    end
    println(repeat("─", 104))

    # 2. Timing & Memory Decomposition
    @printf("  %-26s %14s %14s %14s\n", "Measurement", "Ref (#$id_a)", "New (#$id_b)", "Delta")
    println("  " * repeat("─", 72))
    @printf("  %-26s %14s %14s\n", "Status", String(ca["status"]), String(cb["status"]))
    @printf("  %-26s %11.3f ms %11.3f ms %+11.3f ms\n", "Pure Compute Time", ta, tb, tb - ta)
    @printf("  %-26s %11.3f ms %11.3f ms %+11.3f ms\n", "Total Wall Time", wa, wb, wb - wa)
    @printf("  %-26s %11.3f ms %11.3f ms %+11.3f ms\n", "GC Pause Time", ga, gb, gb - ga)
    @printf("  %-26s %11.3f ms %11.3f ms %+11.3f ms\n", "Verification Time", va, vb, vb - va)
    @printf("  %-26s %11.3f ms %11.3f ms\n", "Sample Spread (Noise)", sa, sb)
    @printf("  %-26s %11.1f KB %11.1f KB %+11.1f KB\n", "Heap Allocations", aa, ab, ab - aa)

    # 3. Side-by-Side BenchmarkLog Profiles
    pha = get(ca, "phases", Dict{String,Any}())
    phb = get(cb, "phases", Dict{String,Any}())
    cnta = get(ca, "counters", Dict{String,Any}())
    cntb = get(cb, "counters", Dict{String,Any}())

    if !isempty(pha) || !isempty(phb)
        println(repeat("─", 104))
        _print_side_by_side_benches(
            "Ref (#$id_a): $(ra["label"])", ta, pha, cnta,
            "New (#$id_b): $(rb["label"])", tb, phb, cntb;
            min_ms=0.001
        )
    end

    # 4. Metrics & Custom Counters
    meta = get(ca, "metrics", Dict{String,Any}())
    metb = get(cb, "metrics", Dict{String,Any}())
    all_m = sort!(collect(union(keys(meta), keys(metb))))
    if !isempty(all_m)
        println(repeat("─", 104))
        printstyled("  Solver Metrics & Trajectory Indicators:\n"; bold=true)
        for mk in all_m
            println("    • $mk:  $(get(meta, mk, "-"))  ->  $(get(metb, mk, "-"))")
        end
    end
    println(repeat("═", 104))
    return (ref=ca, new=cb)
end
