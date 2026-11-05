module Ablate

using Dates
using Printf
using SHA
using Statistics

export @ablate, @case, @warmup, @verify, @phase, @count, @metric, log_result!
export ablate_history, ablate_compare, ablate_regressions, ablate_trace
export ablate_code_diff, ablate_show_patch, ablate_restore!, ablate_pin_baseline!
export plot_cactus, plot_scatter, import_ablation!, pull_remote!

# ==============================================================================
# 1. Minimal Zero-Dependency JSON Encoder / Decoder for JSONL Ledger
# ==============================================================================

function _json_escape(io::IO, s::AbstractString)
    write(io, '"')
    for c in s
        if c == '"'
            write(io, "\\\"")
        elseif c == '\\'
            write(io, "\\\\")
        elseif c == '\n'
            write(io, "\\n")
        elseif c == '\r'
            write(io, "\\r")
        elseif c == '\t'
            write(io, "\\t")
        elseif UInt32(c) < 0x20
            @printf(io, "\\u%04x", UInt32(c))
        else
            write(io, c)
        end
    end
    write(io, '"')
end

function to_json(io::IO, val)
    if val === nothing || val === missing
        write(io, "null")
    elseif val isa Bool
        write(io, val ? "true" : "false")
    elseif val isa Integer
        print(io, val)
    elseif val isa AbstractFloat
        if isfinite(val)
            print(io, Float64(val))
        else
            write(io, "null")
        end
    elseif val isa AbstractString || val isa Symbol
        _json_escape(io, String(val))
    elseif val isa AbstractDict
        write(io, '{')
        first_item = true
        for k in sort!(collect(keys(val)), by=string)
            v = val[k]
            first_item || write(io, ',')
            first_item = false
            _json_escape(io, string(k))
            write(io, ':')
            to_json(io, v)
        end
        write(io, '}')
    elseif val isa AbstractVector || val isa Tuple
        write(io, '[')
        for (i, item) in enumerate(val)
            i > 1 && write(io, ',')
            to_json(io, item)
        end
        write(io, ']')
    else
        _json_escape(io, string(val))
    end
end

function to_json(val)::String
    buf = IOBuffer()
    to_json(buf, val)
    return String(take!(buf))
end

mutable struct _JSONParser
    str::Vector{UInt8}
    pos::Int
end

@inline function _skip_ws!(p::_JSONParser)
    n = length(p.str)
    while p.pos <= n && p.str[p.pos] in (UInt8(' '), UInt8('\t'), UInt8('\n'), UInt8('\r'))
        p.pos += 1
    end
end

function parse_json(s::AbstractString)
    p = _JSONParser(Vector{UInt8}(codeunits(String(s))), 1)
    _skip_ws!(p)
    return _parse_val!(p)
end

function _parse_val!(p::_JSONParser)
    _skip_ws!(p)
    p.pos > length(p.str) && error("Unexpected end of JSON")
    b = p.str[p.pos]
    if b == UInt8('{')
        return _parse_obj!(p)
    elseif b == UInt8('[')
        return _parse_arr!(p)
    elseif b == UInt8('"')
        return _parse_str!(p)
    elseif b == UInt8('t')
        p.pos += 4
        return true
    elseif b == UInt8('f')
        p.pos += 5
        return false
    elseif b == UInt8('n')
        p.pos += 4
        return nothing
    else
        return _parse_num!(p)
    end
end

function _parse_str!(p::_JSONParser)::String
    p.pos += 1
    buf = IOBuffer()
    n = length(p.str)
    while p.pos <= n
        b = p.str[p.pos]
        p.pos += 1
        if b == UInt8('"')
            return String(take!(buf))
        elseif b == UInt8('\\')
            p.pos > n && error("Unterminated escape in JSON string")
            esc_b = p.str[p.pos]
            p.pos += 1
            if esc_b == UInt8('"')
                write(buf, '"')
            elseif esc_b == UInt8('\\')
                write(buf, '\\')
            elseif esc_b == UInt8('/')
                write(buf, '/')
            elseif esc_b == UInt8('n')
                write(buf, '\n')
            elseif esc_b == UInt8('r')
                write(buf, '\r')
            elseif esc_b == UInt8('t')
                write(buf, '\t')
            elseif esc_b == UInt8('u')
                hex_s = String(p.str[p.pos:min(n, p.pos + 3)])
                p.pos += 4
                write(buf, Char(parse(UInt32, hex_s, base=16)))
            else
                write(buf, Char(esc_b))
            end
        else
            write(buf, b)
        end
    end
    error("Unterminated JSON string")
end

function _parse_num!(p::_JSONParser)
    start_pos = p.pos
    n = length(p.str)
    is_float = false
    while p.pos <= n
        b = p.str[p.pos]
        if b in (UInt8('.'), UInt8('e'), UInt8('E'))
            is_float = true
            p.pos += 1
        elseif (b >= UInt8('0') && b <= UInt8('9')) || b in (UInt8('-'), UInt8('+'))
            p.pos += 1
        else
            break
        end
    end
    num_str = String(p.str[start_pos:(p.pos - 1)])
    return is_float ? parse(Float64, num_str) : parse(Int64, num_str)
end

function _parse_arr!(p::_JSONParser)::Vector{Any}
    p.pos += 1
    arr = Any[]
    _skip_ws!(p)
    if p.pos <= length(p.str) && p.str[p.pos] == UInt8(']')
        p.pos += 1
        return arr
    end
    while true
        push!(arr, _parse_val!(p))
        _skip_ws!(p)
        b = p.str[p.pos]
        p.pos += 1
        if b == UInt8(']')
            return arr
        elseif b != UInt8(',')
            error("Expected ',' or ']' in JSON array")
        end
    end
end

function _parse_obj!(p::_JSONParser)::Dict{String,Any}
    p.pos += 1
    obj = Dict{String,Any}()
    _skip_ws!(p)
    if p.pos <= length(p.str) && p.str[p.pos] == UInt8('}')
        p.pos += 1
        return obj
    end
    while true
        _skip_ws!(p)
        k = _parse_str!(p)
        _skip_ws!(p)
        p.str[p.pos] == UInt8(':') || error("Expected ':' in JSON object")
        p.pos += 1
        obj[k] = _parse_val!(p)
        _skip_ws!(p)
        b = p.str[p.pos]
        p.pos += 1
        if b == UInt8('}')
            return obj
        elseif b != UInt8(',')
            error("Expected ',' or '}' in JSON object")
        end
    end
end

# ==============================================================================
# 2. Runtime Context Structs & Global Fast-Path Refs
# ==============================================================================

mutable struct CaseContext
    name::String
    time_wall::Float64
    time_compute::Float64
    time_gc::Float64
    time_compile::Float64
    time_verify::Float64
    time_spread::Float64
    samples::Int
    alloc_bytes::Int64
    jit_retried::Bool
    status::Symbol
    ok::Bool
    verified::Union{Nothing,Bool}
    phases::Dict{String,Float64}
    counters::Dict{String,Int64}
    metrics::Dict{String,Any}
    error_msg::Union{Nothing,String}
end

function CaseContext(name::AbstractString)
    return CaseContext(
        String(name),
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1,
        Int64(0),
        false,
        :OK,
        true,
        nothing,
        Dict{String,Float64}(),
        Dict{String,Int64}(),
        Dict{String,Any}(),
        nothing
    )
end

function _reset_case_for_retry!(c::CaseContext)
    c.time_wall = 0.0
    c.time_compute = 0.0
    c.time_gc = 0.0
    c.time_compile = 0.0
    c.time_verify = 0.0
    c.alloc_bytes = Int64(0)
    c.status = :OK
    c.ok = true
    c.verified = nothing
    empty!(c.phases)
    empty!(c.counters)
    empty!(c.metrics)
    c.error_msg = nothing
end

function _snapshot_case_state(c::CaseContext)
    return (
        time_wall = c.time_wall,
        time_compute = c.time_compute,
        time_gc = c.time_gc,
        time_compile = c.time_compile,
        time_verify = c.time_verify,
        alloc_bytes = c.alloc_bytes,
        status = c.status,
        ok = c.ok,
        verified = c.verified,
        phases = copy(c.phases),
        counters = copy(c.counters),
        metrics = copy(c.metrics),
        error_msg = c.error_msg
    )
end

function _restore_case_state!(c::CaseContext, st)
    c.time_wall = st.time_wall
    c.time_compute = st.time_compute
    c.time_gc = st.time_gc
    c.time_compile = st.time_compile
    c.time_verify = st.time_verify
    c.alloc_bytes = st.alloc_bytes
    c.status = st.status
    c.ok = st.ok
    c.verified = st.verified
    c.phases = copy(st.phases)
    c.counters = copy(st.counters)
    c.metrics = copy(st.metrics)
    c.error_msg = st.error_msg
end

mutable struct RunContext
    run_id::Int
    label::String
    suite::String
    repo_root::String
    ablation_dir::String
    cases_file::String
    timestamp::String
    git_commit::String
    git_branch::String
    git_dirty::Bool
    patch_hash::String
    code_signature::String
    env_info::Dict{String,Any}
    params::Dict{String,Any}
    retry_on_jit::Bool
    gc_before_case::Bool
    min_sample_time_s::Float64
    max_samples::Int
    timeout_s::Float64
    cases::Vector{CaseContext}
end

const ACTIVE_RUN = Ref{Union{Nothing,RunContext}}(nothing)
const ACTIVE_CASE = Ref{Union{Nothing,CaseContext}}(nothing)
const IS_ACTIVE = Ref{Bool}(false)

# ==============================================================================
# 3. Git Snapshot & Runtime Environment / Hardware Fingerprinting
# ==============================================================================

function find_repo_root(start_dir::AbstractString=pwd())::String
    cur = abspath(start_dir)
    while true
        if isdir(joinpath(cur, ".git")) || isfile(joinpath(cur, ".git"))
            return cur
        end
        parent_dir = dirname(cur)
        parent_dir == cur && return abspath(start_dir)
        cur = parent_dir
    end
end

function ensure_ablation_dirs(repo_root::AbstractString)::String
    ab_dir = joinpath(repo_root, ".ablation")
    mkpath(joinpath(ab_dir, "patches"))
    mkpath(joinpath(ab_dir, "cases"))
    gitignore = joinpath(ab_dir, ".gitignore")
    if !isfile(gitignore)
        write(gitignore, "# Ignore scratch temp dirs\ntmp/\n")
    end
    return ab_dir
end

function _read_cmd_safe(cmd::Cmd)::Tuple{Bool,String}
    out = IOBuffer()
    err = IOBuffer()
    try
        proc = run(pipeline(ignorestatus(cmd), stdout=out, stderr=err))
        return success(proc), String(take!(out))
    catch
        return false, ""
    end
end

function capture_env_info()::Dict{String,Any}
    cpus = Sys.cpu_info()
    cpu_model = isempty(cpus) ? "unknown" : strip(cpus[1].model)
    return Dict{String,Any}(
        "host" => gethostname(),
        "cpu_model" => cpu_model,
        "julia_version" => string(VERSION),
        "nthreads" => Threads.nthreads(),
        "opt_level" => Base.JLOptions().opt_level,
        "check_bounds" => Int(Base.JLOptions().check_bounds)
    )
end

function _same_hardware(ra::Dict{String,Any}, rb::Dict{String,Any})::Bool
    ea = get(ra, "env_info", Dict{String,Any}())
    eb = get(rb, "env_info", Dict{String,Any}())
    ha = get(ea, "host", "")
    hb = get(eb, "host", "")
    ca = get(ea, "cpu_model", "")
    cb = get(eb, "cpu_model", "")
    (isempty(ha) || isempty(hb)) && return true
    return ha == hb && (isempty(ca) || isempty(cb) || ca == cb)
end

"""
    capture_code_snapshot(repo_root::AbstractString, ab_dir::AbstractString)

Captures the exact git commit, branch, and any uncommitted changes (both tracked
modifications via `git diff HEAD` and untracked `.jl` files).
Writes the unified patch to `.ablation/patches/<patch_hash>.diff`.
"""
function capture_code_snapshot(repo_root::AbstractString, ab_dir::AbstractString)
    ok_c, commit_raw = _read_cmd_safe(Cmd(`git rev-parse --short=10 HEAD`, dir=repo_root))
    git_commit = ok_c ? strip(commit_raw) : "nogit"

    ok_b, branch_raw = _read_cmd_safe(Cmd(`git rev-parse --abbrev-ref HEAD`, dir=repo_root))
    git_branch = ok_b ? strip(branch_raw) : "unknown"

    if git_commit == "nogit"
        return (commit="nogit", branch="unknown", dirty=false, patch_hash="", signature="nogit")
    end

    _, diff_tracked = _read_cmd_safe(Cmd(`git diff HEAD -- . ":(exclude).ablation"`, dir=repo_root))
    _, untracked_raw = _read_cmd_safe(Cmd(`git ls-files --others --exclude-standard -- src test`, dir=repo_root))
    untracked_buf = IOBuffer()
    for rel in split(untracked_raw, '\n')
        rel_s = strip(rel)
        isempty(rel_s) && continue
        endswith(rel_s, ".jl") || continue
        full_p = joinpath(repo_root, rel_s)
        isfile(full_p) || continue
        _, file_diff = _read_cmd_safe(Cmd(`git diff --no-index -- /dev/null $rel_s`, dir=repo_root))
        write(untracked_buf, file_diff)
    end

    full_patch = diff_tracked * String(take!(untracked_buf))
    if isempty(strip(full_patch))
        return (
            commit=String(git_commit),
            branch=String(git_branch),
            dirty=false,
            patch_hash="",
            signature=String(git_commit)
        )
    else
        p_hash = bytes2hex(sha256(full_patch))[1:12]
        patch_path = joinpath(ab_dir, "patches", "$(p_hash).diff")
        if !isfile(patch_path)
            write(patch_path, full_patch)
        end
        sig = "$(git_commit)+$(p_hash[1:8])"
        return (
            commit=String(git_commit),
            branch=String(git_branch),
            dirty=true,
            patch_hash=p_hash,
            signature=sig
        )
    end
end

# ==============================================================================
# 4. General In-Process Instrumentation API
# ==============================================================================

function group_indexed_phases(raw_phases::AbstractDict; scale::Float64=1.0)::Dict{String,Float64}
    out = Dict{String,Float64}()
    for (k, v) in raw_phases
        k_s = string(k)
        m = match(r"^([a-zA-Z_]+?)_?\d+$", k_s)
        base_k = m !== nothing ? String(m.captures[1]) : k_s
        out[base_k] = get(out, base_k, 0.0) + Float64(v) * scale
    end
    return out
end

function _finalize_case_verification_status!(ctx::CaseContext)
    if ctx.verified === false
        ctx.ok = false
        ctx.status = :UNVERIFIED
    elseif ctx.ok
        if ctx.verified === true
            ctx.status = :VERIFIED
        elseif ctx.status == :OK
            ctx.status = :UNVERIFIED_OK
        end
    else
        if ctx.status in (:OK, :VERIFIED, :UNVERIFIED_OK)
            ctx.status = :FAIL
        end
    end
end

"""
    log_result!(; ok=nothing, solved=nothing, verified=nothing, status=nothing,
                  phases=nothing, phase_unit=:s, group_phases=false, counters=nothing, metrics...)

Domain-agnostic logger for recording the outcome, phase timings, counters, and arbitrary
keyword metrics of the active `@case`.
"""
function log_result!(;
    ok::Union{Nothing,Bool}=nothing,
    solved::Union{Nothing,Bool}=nothing,
    verified::Union{Nothing,Bool}=nothing,
    status::Union{Nothing,Symbol,AbstractString}=nothing,
    phases::Union{Nothing,AbstractDict}=nothing,
    phase_unit::Symbol=:s,
    group_phases::Bool=false,
    counters::Union{Nothing,AbstractDict}=nothing,
    kwargs...
)
    ctx = ACTIVE_CASE[]
    ctx === nothing && return nothing

    if verified !== nothing
        ctx.verified = verified
    end

    is_ok = if ok !== nothing
        ok
    elseif solved !== nothing
        solved
    else
        ctx.ok
    end
    ctx.ok = is_ok

    if status !== nothing
        ctx.status = Symbol(status)
    else
        _finalize_case_verification_status!(ctx)
    end

    if phases !== nothing
        scale = phase_unit == :ms ? 1e-3 : (phase_unit == :us ? 1e-6 : 1.0)
        src = group_phases ? group_indexed_phases(phases; scale=scale) :
              Dict{String,Float64}(string(k) => Float64(v) * scale for (k, v) in phases)
        for (k, v) in src
            ctx.phases[k] = get(ctx.phases, k, 0.0) + v
        end
    end

    if counters !== nothing
        for (k, v) in counters
            ks = string(k)
            ctx.counters[ks] = get(ctx.counters, ks, Int64(0)) + Int64(v)
        end
    end

    for (k, v) in kwargs
        if v !== nothing
            ctx.metrics[string(k)] = v
        end
    end
    return nothing
end

@inline function _add_phase_time!(phase_name::Symbol, dt::Float64)
    ctx = ACTIVE_CASE[]
    ctx === nothing && return
    k = String(phase_name)
    ctx.phases[k] = get(ctx.phases, k, 0.0) + dt
end

@inline function _add_verify_time!(dt::Float64, is_valid::Bool)
    ctx = ACTIVE_CASE[]
    ctx === nothing && return
    ctx.time_verify += dt
    ctx.verified = (ctx.verified === nothing) ? is_valid : (ctx.verified && is_valid)
    _finalize_case_verification_status!(ctx)
end

@inline function _add_counter!(counter_name::Symbol, delta::Integer)
    ctx = ACTIVE_CASE[]
    ctx === nothing && return
    k = String(counter_name)
    ctx.counters[k] = get(ctx.counters, k, Int64(0)) + Int64(delta)
end

@inline function _set_metric!(metric_name::Symbol, val)
    ctx = ACTIVE_CASE[]
    ctx === nothing && return
    ctx.metrics[String(metric_name)] = val
end

macro phase(name_expr, body_expr)
    return quote
        if $(Ablate.IS_ACTIVE)[]
            local _t0 = time_ns()
            local _val = $(esc(body_expr))
            local _dt = (time_ns() - _t0) / 1e9
            $(Ablate._add_phase_time!)($(esc(name_expr)), _dt)
            _val
        else
            $(esc(body_expr))
        end
    end
end

macro verify(body_expr)
    return quote
        if $(Ablate.IS_ACTIVE)[]
            local _t0 = time_ns()
            local _ok = Bool($(esc(body_expr)))
            local _dt = (time_ns() - _t0) / 1e9
            $(Ablate._add_verify_time!)(_dt, _ok)
            _ok
        else
            Bool($(esc(body_expr)))
        end
    end
end

macro count(name_expr, delta_expr=1)
    return quote
        if $(Ablate.IS_ACTIVE)[]
            $(Ablate._add_counter!)($(esc(name_expr)), $(esc(delta_expr)))
        end
    end
end

macro metric(name_expr, val_expr)
    return quote
        if $(Ablate.IS_ACTIVE)[]
            $(Ablate._set_metric!)($(esc(name_expr)), $(esc(val_expr)))
        end
    end
end

macro warmup(body_expr)
    return quote
        local _prev_active = $(Ablate.IS_ACTIVE)[]
        local _prev_case = $(Ablate.ACTIVE_CASE)[]
        $(Ablate.IS_ACTIVE)[] = false
        $(Ablate.ACTIVE_CASE)[] = nothing
        try
            $(esc(body_expr))
        finally
            $(Ablate.IS_ACTIVE)[] = _prev_active
            $(Ablate.ACTIVE_CASE)[] = _prev_case
        end
    end
end

# ==============================================================================
# 5. Ledger Read/Write & Scientific Case Execution (@ablate and @case)
# ==============================================================================

function load_runs(ab_dir::AbstractString)::Vector{Dict{String,Any}}
    runs_file = joinpath(ab_dir, "runs.jsonl")
    isfile(runs_file) || return Dict{String,Any}[]
    runs = Dict{String,Any}[]
    for line in eachline(runs_file)
        s = strip(line)
        isempty(s) && continue
        push!(runs, parse_json(s))
    end
    return runs
end

function load_cases(ab_dir::AbstractString, run_id::Integer)::Vector{Dict{String,Any}}
    cases_file = joinpath(ab_dir, "cases", "run_$(run_id).jsonl")
    isfile(cases_file) || return Dict{String,Any}[]
    cases = Dict{String,Any}[]
    for line in eachline(cases_file)
        s = strip(line)
        isempty(s) && continue
        push!(cases, parse_json(s))
    end
    return cases
end

function load_baselines(ab_dir::AbstractString)::Dict{String,Int}
    b_file = joinpath(ab_dir, "baselines.json")
    isfile(b_file) || return Dict{String,Int}()
    raw = parse_json(read(b_file, String))
    return Dict{String,Int}(k => Int(v) for (k, v) in raw)
end

function save_baselines(ab_dir::AbstractString, baselines::Dict{String,Int})
    b_file = joinpath(ab_dir, "baselines.json")
    write(b_file, to_json(baselines) * "\n")
end

function _case_to_dict(c::CaseContext)::Dict{String,Any}
    _finalize_case_verification_status!(c)
    d = Dict{String,Any}(
        "name" => c.name,
        "status" => String(c.status),
        "ok" => c.ok,
        "verified" => c.verified,
        "time_wall" => c.time_wall,
        "time_compute" => c.time_compute,
        "time_gc" => c.time_gc,
        "time_compile" => c.time_compile,
        "time_verify" => c.time_verify,
        "time_spread" => c.time_spread,
        "samples" => c.samples,
        "alloc_bytes" => c.alloc_bytes,
        "jit_retried" => c.jit_retried,
        "phases" => c.phases,
        "counters" => c.counters,
        "metrics" => c.metrics
    )
    if c.error_msg !== nothing
        d["error_msg"] = c.error_msg
    end
    return d
end

function _geomean(xs::Vector{Float64}; floor_val::Float64=1e-5)::Float64
    isempty(xs) && return 0.0
    return exp(mean(log(max(x, floor_val)) for x in xs))
end

function _compute_par2(cases::Vector{CaseContext}, timeout_s::Float64)::Float64
    isempty(cases) && return 0.0
    tot = 0.0
    for c in cases
        if c.ok && c.status != :UNVERIFIED && c.time_compute <= timeout_s
            tot += c.time_compute
        else
            tot += 2.0 * timeout_s
        end
    end
    return tot / length(cases)
end

function _start_run(
    label::AbstractString;
    suite::AbstractString="default",
    dir::AbstractString=pwd(),
    retry_on_jit::Bool=true,
    gc_before_case::Bool=false,
    min_sample_time_s::Float64=0.012,
    max_samples::Int=3,
    timeout_s::Float64=10.0,
    params::Dict{String,Any}=Dict{String,Any}()
)::RunContext
    repo_root = find_repo_root(dir)
    ab_dir = ensure_ablation_dirs(repo_root)
    existing = load_runs(ab_dir)
    next_id = isempty(existing) ? 1 : maximum(Int(r["run_id"]) for r in existing) + 1

    snap = capture_code_snapshot(repo_root, ab_dir)
    env_info = capture_env_info()
    ts = Dates.format(now(), "yyyy-mm-ddTHH:MM:SS")
    cases_file = joinpath(ab_dir, "cases", "run_$(next_id).jsonl")

    ctx = RunContext(
        next_id,
        String(label),
        String(suite),
        repo_root,
        ab_dir,
        cases_file,
        ts,
        snap.commit,
        snap.branch,
        snap.dirty,
        snap.patch_hash,
        snap.signature,
        env_info,
        params,
        retry_on_jit,
        gc_before_case,
        min_sample_time_s,
        max_samples,
        timeout_s,
        CaseContext[]
    )
    ACTIVE_RUN[] = ctx
    IS_ACTIVE[] = true

    printstyled("▶ Ablate Run #$(next_id) [$(suite)] "; bold=true, color=:cyan)
    print("— \"$(label)\" ")
    printstyled("($(snap.signature) @ $(env_info["host"]))\n"; color=snap.dirty ? :yellow : :green)
    return ctx
end

function _populate_timed_stats!(c::CaseContext, stats)
    c.time_wall = Float64(stats.time)
    c.time_gc = Float64(stats.gctime)
    c.time_compile = hasproperty(stats, :compile_time) ? Float64(stats.compile_time) : 0.0
    c.alloc_bytes = Int64(stats.bytes)
    c.time_compute = max(0.0, c.time_wall - c.time_gc - c.time_compile - c.time_verify)
end

function _finish_case!(c::CaseContext)
    _finalize_case_verification_status!(c)
    run_ctx = ACTIVE_RUN[]
    if run_ctx !== nothing
        push!(run_ctx.cases, c)
        open(run_ctx.cases_file, "a") do io
            to_json(io, _case_to_dict(c))
            write(io, '\n')
        end
    end
end

function _finish_run!(ctx::RunContext; auto_compare::Bool=true, quiet::Bool=false)
    ACTIVE_RUN[] = nothing
    ACTIVE_CASE[] = nothing
    IS_ACTIVE[] = false

    n_total = length(ctx.cases)
    n_ok = count(c -> c.ok, ctx.cases)
    n_verified = count(c -> c.ok && c.verified === true, ctx.cases)
    n_unverified_ok = count(c -> c.status == :UNVERIFIED_OK, ctx.cases)
    n_unverified_fail = count(c -> c.status == :UNVERIFIED, ctx.cases)
    n_jit_retried = count(c -> c.jit_retried, ctx.cases)

    # Suite fingerprint (Guardrail 4: detect silent benchmark subset drift)
    sorted_names = sort!([c.name for c in ctx.cases])
    suite_hash = bytes2hex(sha256(join(sorted_names, "\n")))[1:10]

    times = [c.time_compute for c in ctx.cases]
    total_compute = sum(times; init=0.0)
    total_wall = sum((c.time_wall for c in ctx.cases); init=0.0)
    total_alloc = sum((c.alloc_bytes for c in ctx.cases); init=Int64(0))
    geomean_time = _geomean(times)
    par2_score = _compute_par2(ctx.cases, ctx.timeout_s)
    median_time = isempty(times) ? 0.0 : median(times)
    p90_time = isempty(times) ? 0.0 : quantile(times, 0.90)

    phase_totals = Dict{String,Float64}()
    for c in ctx.cases
        for (k, v) in c.phases
            phase_totals[k] = get(phase_totals, k, 0.0) + v
        end
    end

    run_record = Dict{String,Any}(
        "run_id" => ctx.run_id,
        "timestamp" => ctx.timestamp,
        "label" => ctx.label,
        "suite" => ctx.suite,
        "suite_hash" => suite_hash,
        "timeout_s" => ctx.timeout_s,
        "git_commit" => ctx.git_commit,
        "git_branch" => ctx.git_branch,
        "git_dirty" => ctx.git_dirty,
        "patch_hash" => ctx.patch_hash,
        "code_signature" => ctx.code_signature,
        "env_info" => ctx.env_info,
        "params" => ctx.params,
        "n_total" => n_total,
        "n_ok" => n_ok,
        "n_verified" => n_verified,
        "n_unverified_ok" => n_unverified_ok,
        "n_unverified" => n_unverified_fail,
        "n_jit_retried" => n_jit_retried,
        "total_compute" => total_compute,
        "total_wall" => total_wall,
        "total_alloc_bytes" => total_alloc,
        "geomean_time" => geomean_time,
        "par2_score" => par2_score,
        "median_time" => median_time,
        "p90_time" => p90_time,
        "phase_totals" => phase_totals
    )

    runs_file = joinpath(ctx.ablation_dir, "runs.jsonl")
    open(runs_file, "a") do io
        to_json(io, run_record)
        write(io, '\n')
    end

    if !quiet
        alloc_mb = total_alloc / (1024.0 * 1024.0)
        ver_str = n_verified == n_ok && n_ok > 0 ? "$n_verified/$n_total verified" :
                  "$n_ok/$n_total ok ($n_verified verified, $n_unverified_ok unverified)"
        jit_note = n_jit_retried > 0 ? " | JIT-retried: $(n_jit_retried)" : ""
        printstyled(@sprintf(
            "✔ Run #%d finished: %s | Compute: %.3fs | PAR-2: %.2fms | Geomean: %.2fms | Alloc: %.1fMB%s\n",
            ctx.run_id, ver_str, total_compute, par2_score * 1e3, geomean_time * 1e3, alloc_mb, jit_note
        ); bold=true, color=(n_ok == n_total && n_unverified_fail == 0 && n_unverified_ok == 0 ? :green : :yellow))
    end

    if auto_compare && !quiet
        all_runs = load_runs(ctx.ablation_dir)
        # Guardrail 5: auto_compare only matches runs from the same suite AND same hardware
        same_hw_runs = filter(r -> r["suite"] == ctx.suite && Int(r["run_id"]) < ctx.run_id && _same_hardware(r, run_record), all_runs)
        if !isempty(same_hw_runs)
            baselines = load_baselines(ctx.ablation_dir)
            base_id = get(baselines, ctx.suite, -1)
            ref_id = if base_id != -1 && any(Int(r["run_id"]) == base_id for r in same_hw_runs)
                base_id
            else
                Int(same_hw_runs[end]["run_id"])
            end
            ablate_compare(ref_id, ctx.run_id; dir=ctx.repo_root)
        end
    end

    return run_record
end

"""
    @case name begin ... end

Executes a benchmark case inside `@ablate`:
1. Measures wall time, GC time, JIT compilation time, and heap allocations via `Base.@timed`.
2. If `retry_on_jit=true` and `compile_time > 0`, automatically resets and re-runs once so
   JIT compilation never contaminates timings.
3. Adaptive Micro-Sampling: if the compiled run finishes faster than `min_sample_time_s`
   (default 12ms), repeats up to `max_samples` (default 3) within the 12ms budget, keeping
   the minimum compute time and recording the empirical noise spread `time_spread`.
"""
macro case(name_expr, body_expr)
    return quote
        local _run = $(Ablate.ACTIVE_RUN)[]
        local _c = $(Ablate.CaseContext)(string($(esc(name_expr))))
        local _prev_c = $(Ablate.ACTIVE_CASE)[]
        $(Ablate.ACTIVE_CASE)[] = _c
        try
            if _run !== nothing && _run.gc_before_case
                GC.gc(false)
            end
            local _stats = Base.@timed begin
                $(esc(body_expr))
            end
            $(Ablate._populate_timed_stats!)(_c, _stats)

            # Guardrail: Auto-retry if JIT compilation occurred during the measurement
            if _run !== nothing && _run.retry_on_jit && _c.time_compile > 0.0 && _c.status != :ERROR
                $(Ablate._reset_case_for_retry!)(_c)
                _c.jit_retried = true
                if _run.gc_before_case
                    GC.gc(false)
                end
                local _stats2 = Base.@timed begin
                    $(esc(body_expr))
                end
                $(Ablate._populate_timed_stats!)(_c, _stats2)
            end

            # Guardrail 3: Adaptive Micro-Sampling for fast cases (< min_sample_time_s)
            local _min_budget = _run !== nothing ? _run.min_sample_time_s : 0.0
            local _max_samp = _run !== nothing ? _run.max_samples : 1
            if _max_samp > 1 && _c.time_compile == 0.0 && _c.status != :ERROR && _c.time_compute < _min_budget
                local _best_state = $(Ablate._snapshot_case_state)(_c)
                local _min_t = _c.time_compute
                local _max_t = _c.time_compute
                local _elapsed_budget = _c.time_wall
                local _n_samp = 1
                while _n_samp < _max_samp && _elapsed_budget < _min_budget
                    $(Ablate._reset_case_for_retry!)(_c)
                    local _st_k = Base.@timed begin
                        $(esc(body_expr))
                    end
                    $(Ablate._populate_timed_stats!)(_c, _st_k)
                    _n_samp += 1
                    _elapsed_budget += _c.time_wall
                    _max_t = max(_max_t, _c.time_compute)
                    if _c.time_compute < _min_t
                        _min_t = _c.time_compute
                        _best_state = $(Ablate._snapshot_case_state)(_c)
                    end
                end
                $(Ablate._restore_case_state!)(_c, _best_state)
                _c.samples = _n_samp
                _c.time_spread = _max_t - _min_t
            end
        catch _err
            _c.status = :ERROR
            _c.ok = false
            _c.error_msg = sprint(showerror, _err)
        finally
            $(Ablate._finish_case!)(_c)
            $(Ablate.ACTIVE_CASE)[] = _prev_c
        end
        _c
    end
end

macro ablate(label_expr, args...)
    isempty(args) && error("@ablate requires a label and a body block")
    body_expr = args[end]
    kw_args = args[1:(end - 1)]

    suite_ex = :("default")
    dir_ex = :(pwd())
    auto_cmp_ex = :(true)
    quiet_ex = :(false)
    retry_jit_ex = :(true)
    gc_case_ex = :(false)
    min_samp_ex = :(0.012)
    max_samp_ex = :(3)
    timeout_ex = :(10.0)
    param_pairs = Expr[]

    for arg in kw_args
        if arg isa Expr && arg.head == :(=)
            k = arg.args[1]
            v = arg.args[2]
            if k == :suite
                suite_ex = v
            elseif k == :dir
                dir_ex = v
            elseif k == :auto_compare
                auto_cmp_ex = v
            elseif k == :quiet
                quiet_ex = v
            elseif k == :retry_on_jit
                retry_jit_ex = v
            elseif k == :gc_before_case
                gc_case_ex = v
            elseif k == :min_sample_time_s
                min_samp_ex = v
            elseif k == :max_samples
                max_samp_ex = v
            elseif k == :timeout_s
                timeout_ex = v
            else
                push!(param_pairs, :($(string(k)) => $(esc(v))))
            end
        end
    end

    return quote
        local _params = Dict{String,Any}($(param_pairs...))
        local _run_ctx = $(Ablate._start_run)(
            $(esc(label_expr));
            suite=$(esc(suite_ex)),
            dir=$(esc(dir_ex)),
            retry_on_jit=$(esc(retry_jit_ex)),
            gc_before_case=$(esc(gc_case_ex)),
            min_sample_time_s=$(esc(min_samp_ex)),
            max_samples=$(esc(max_samp_ex)),
            timeout_s=$(esc(timeout_ex)),
            params=_params
        )
        try
            $(esc(body_expr))
        finally
            $(Ablate._finish_run!)(_run_ctx; auto_compare=$(esc(auto_cmp_ex)), quiet=$(esc(quiet_ex)))
        end
    end
end

# ==============================================================================
# 6. General Root-Cause Attribution, Comparison, Trace & Code Diff Tools
# ==============================================================================

function _resolve_run_id(
    spec,
    runs::Vector{Dict{String,Any}},
    ab_dir::AbstractString;
    suite::Union{Nothing,AbstractString}=nothing
)::Int
    isempty(runs) && error("No ablation runs recorded in $(ab_dir)")
    filtered = suite === nothing ? runs : filter(r -> r["suite"] == suite, runs)
    isempty(filtered) && error("No ablation runs found for suite '$(suite)'")

    if spec isa Integer
        return Int(spec)
    elseif spec == :last || spec == "last"
        return Int(filtered[end]["run_id"])
    elseif spec == :prev || spec == "prev"
        length(filtered) < 2 && return Int(filtered[end]["run_id"])
        return Int(filtered[end - 1]["run_id"])
    elseif spec == :baseline || spec == "baseline"
        baselines = load_baselines(ab_dir)
        st = suite === nothing ? String(filtered[end]["suite"]) : String(suite)
        return get(baselines, st, Int(filtered[1]["run_id"]))
    else
        error("Unknown run specifier: $spec (use an integer ID, :last, :prev, or :baseline)")
    end
end

function ablate_history(; suite::Union{Nothing,AbstractString}=nothing, limit::Int=25, dir::AbstractString=pwd())
    repo_root = find_repo_root(dir)
    ab_dir = ensure_ablation_dirs(repo_root)
    runs = load_runs(ab_dir)
    if suite !== nothing
        runs = filter(r -> r["suite"] == suite, runs)
    end
    if isempty(runs)
        println("No ablation runs recorded yet in $(ab_dir).")
        return runs
    end
    baselines = load_baselines(ab_dir)
    shown = runs[max(1, length(runs) - limit + 1):end]

    println(repeat("─", 122))
    @printf("%-5s %-19s %-10s %-22s %-18s %-10s %-9s %-9s %-9s %-8s\n",
        "Run", "Timestamp", "Suite", "Label", "Code Snapshot", "Verified", "Compute", "PAR-2", "Geomean", "Alloc")
    println(repeat("─", 122))
    for r in shown
        rid = Int(r["run_id"])
        st = String(r["suite"])
        is_base = get(baselines, st, -1) == rid
        tag = is_base ? "*#$(rid)" : " #$(rid)"
        lbl = String(r["label"])
        lbl_trunc = length(lbl) > 21 ? first(lbl, 18) * "..." : lbl
        st_trunc = length(st) > 9 ? first(st, 9) : st
        n_ok = Int(get(r, "n_ok", get(r, "n_solved", 0)))
        n_ver = Int(get(r, "n_verified", n_ok))
        n_tot = Int(r["n_total"])
        ver_str = n_ver == n_ok ? "$(n_ver)/$(n_tot)" : "$(n_ver)*($(n_ok))/$(n_tot)"
        t_comp = Float64(get(r, "total_compute", get(r, "total_time", 0.0)))
        tot_s = @sprintf("%.3fs", t_comp)
        par2_ms = @sprintf("%.2fms", Float64(get(r, "par2_score", 0.0)) * 1e3)
        gm_ms = @sprintf("%.2fms", Float64(r["geomean_time"]) * 1e3)
        alloc_mb = Float64(get(r, "total_alloc_bytes", 0)) / (1024.0 * 1024.0)
        alloc_s = @sprintf("%.1fMB", alloc_mb)
        color = (n_ver == n_tot && n_ok == n_tot) ? :normal : :yellow
        printstyled(@sprintf("%-5s %-19s %-10s %-22s %-18s %-10s %-9s %-9s %-9s %-8s\n",
            tag, r["timestamp"], st_trunc, lbl_trunc, r["code_signature"], ver_str, tot_s, par2_ms, gm_ms, alloc_s); color=color)
    end
    println(repeat("─", 122))
    return shown
end

function _attribute_cause(ca::Dict{String,Any}, cb::Dict{String,Any})::String
    reasons = String[]

    sa = String(get(ca, "status", "OK"))
    sb = String(get(cb, "status", "OK"))
    if sa != sb
        push!(reasons, "STATUS:$sa->$sb")
    end

    ma = get(ca, "metrics", Dict{String,Any}())
    mb = get(cb, "metrics", Dict{String,Any}())
    for mk in sort!(collect(union(keys(ma), keys(mb))))
        va = get(ma, mk, nothing)
        vb = get(mb, mk, nothing)
        if va !== nothing && vb !== nothing && va != vb
            push!(reasons, "$mk:$va->$vb")
        end
    end

    pa = get(ca, "phases", get(ca, "timings", Dict{String,Any}()))
    pb = get(cb, "phases", get(cb, "timings", Dict{String,Any}()))
    all_phases = union(keys(pa), keys(pb))
    if !isempty(all_phases)
        best_phase = ""
        best_abs_delta = 0.0
        ta_c = Float64(get(ca, "time_compute", get(ca, "time_total", 0.0)))
        tb_c = Float64(get(cb, "time_compute", get(cb, "time_total", 0.0)))
        total_delta = tb_c - ta_c
        for p in all_phases
            va = Float64(get(pa, p, 0.0))
            vb = Float64(get(pb, p, 0.0))
            d = vb - va
            if abs(d) > abs(best_abs_delta)
                best_abs_delta = d
                best_phase = String(p)
            end
        end
        if !isempty(best_phase) && abs(best_abs_delta) >= 1e-4
            sgn = best_abs_delta >= 0 ? "+" : ""
            pct = abs(total_delta) > 1e-5 ? round(Int, 100 * abs(best_abs_delta) / max(abs(total_delta), abs(best_abs_delta))) : 100
            push!(reasons, @sprintf("PHASE:%s(%s%.1fms, %d%%)", best_phase, sgn, best_abs_delta * 1e3, pct))
        end
    end

    alloc_a = Int64(get(ca, "alloc_bytes", 0))
    alloc_b = Int64(get(cb, "alloc_bytes", 0))
    if alloc_a > 0 && abs(alloc_b - alloc_a) / alloc_a >= 0.10 && abs(alloc_b - alloc_a) >= 16384
        alloc_pct = 100.0 * (alloc_b - alloc_a) / alloc_a
        push!(reasons, @sprintf("ALLOC:%+.0f%%", alloc_pct))
    end

    cnt_a = get(ca, "counters", Dict{String,Any}())
    cnt_b = get(cb, "counters", Dict{String,Any}())
    for ck in sort!(collect(union(keys(cnt_a), keys(cnt_b))))
        va = Int(get(cnt_a, ck, 0))
        vb = Int(get(cnt_b, ck, 0))
        if va != vb
            push!(reasons, "$ck:$va->$vb")
        end
    end

    return isempty(reasons) ? "compute-time" : join(reasons, " | ")
end

"""
    ablate_compare(run_a=:prev, run_b=:last; suite=nothing, threshold=0.15, min_delta_s=0.001, show_all=false, dir=pwd())

Compares `run_b` against reference `run_a` enforcing the 5 scientific guardrails:
1. Checks Hardware & Runtime Environment consistency (`host`, `cpu_model`, `nthreads`, `opt_level`).
2. Checks Suite Fingerprint (`suite_hash`) and warns if cases were added or removed.
3. Computes Intersection Compute/Geomean (over jointly solved cases) alongside full-suite PAR-2 score.
4. Tracks explicit Verification counts (`Verified` vs `Unverified`).
5. Filters per-case timing shifts against both `threshold` and the measured multi-sample noise spread (`time_spread`).
"""
function ablate_compare(
    run_a=:prev,
    run_b=:last;
    suite::Union{Nothing,AbstractString}=nothing,
    threshold::Float64=0.15,
    min_delta_s::Float64=0.001,
    show_all::Bool=false,
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

    println(repeat("═", 122))
    printstyled(@sprintf("ABLATION COMPARISON: Run #%d (ref) vs Run #%d (new)  [suite: %s]\n",
        id_a, id_b, target_suite); bold=true, color=:cyan)

    # Guardrail 5: Hardware & Runtime Environment Consistency
    env_a = get(ra, "env_info", Dict{String,Any}())
    env_b = get(rb, "env_info", Dict{String,Any}())
    if !_same_hardware(ra, rb)
        ha = "$(get(env_a, "host", "?")) ($(get(env_a, "cpu_model", "?")))"
        hb = "$(get(env_b, "host", "?")) ($(get(env_b, "cpu_model", "?")))"
        printstyled("  ⚠ CROSS-HARDWARE WARNING: Run #$id_a ran on [$ha] vs Run #$id_b on [$hb].\n"; bold=true, color=:red)
        printstyled("    Wall/compute times are not directly comparable across different CPUs; inspect allocations & metrics instead.\n"; color=:yellow)
    elseif !isempty(env_a) && !isempty(env_b) && env_a != env_b
        printstyled("  ⚠ Runtime Warning: Julia settings differ between Run #$id_a and Run #$id_b: $env_a vs $env_b\n"; color=:yellow)
    end

    # Guardrail 4: Suite Fingerprint & Drift Check
    sh_a = get(ra, "suite_hash", "")
    sh_b = get(rb, "suite_hash", "")
    if !isempty(sh_a) && !isempty(sh_b) && sh_a != sh_b
        only_a = setdiff(keys(cases_a), keys(cases_b))
        only_b = setdiff(keys(cases_b), keys(cases_a))
        printstyled("  ⚠ SUITE DRIFT WARNING: Benchmark case set changed (-$(length(only_a)) removed, +$(length(only_b)) added)!\n"; bold=true, color=:yellow)
    end

    # Guardrail 1 & 2: Intersection Compute/Geomean + PAR-2 + Explicit Verified Counts
    common_names = sort!(collect(intersect(keys(cases_a), keys(cases_b))))
    joint_ok = filter(n -> Bool(get(cases_a[n], "ok", true)) && Bool(get(cases_b[n], "ok", true)), common_names)
    inter_ta = [Float64(get(cases_a[n], "time_compute", get(cases_a[n], "time_total", 0.0))) for n in joint_ok]
    inter_tb = [Float64(get(cases_b[n], "time_compute", get(cases_b[n], "time_total", 0.0))) for n in joint_ok]

    ok_a = Int(get(ra, "n_ok", get(ra, "n_solved", 0)))
    ok_b = Int(get(rb, "n_ok", get(rb, "n_solved", 0)))
    ver_a = Int(get(ra, "n_verified", ok_a))
    ver_b = Int(get(rb, "n_verified", ok_b))
    par2_a = Float64(get(ra, "par2_score", 0.0)) * 1e3
    par2_b = Float64(get(rb, "par2_score", 0.0)) * 1e3
    al_a = Float64(get(ra, "total_alloc_bytes", 0)) / (1024.0 * 1024.0)
    al_b = Float64(get(rb, "total_alloc_bytes", 0)) / (1024.0 * 1024.0)

    @printf("  Ref (#%d): \"%s\"  | Code: %s  | Verified: %d/%d (OK:%d)  | Common Compute: %.3fs  | PAR-2: %.2fms  | Geomean: %.2fms  | Alloc: %.1fMB\n",
        id_a, ra["label"], ra["code_signature"], ver_a, Int(ra["n_total"]), ok_a,
        sum(inter_ta; init=0.0), par2_a, _geomean(inter_ta) * 1e3, al_a)
    @printf("  New (#%d): \"%s\"  | Code: %s  | Verified: %d/%d (OK:%d)  | Common Compute: %.3fs  | PAR-2: %.2fms  | Geomean: %.2fms  | Alloc: %.1fMB\n",
        id_b, rb["label"], rb["code_signature"], ver_b, Int(rb["n_total"]), ok_b,
        sum(inter_tb; init=0.0), par2_b, _geomean(inter_tb) * 1e3, al_b)

    # Aggregate Phase Breakdown
    pa = get(ra, "phase_totals", Dict{String,Any}())
    pb = get(rb, "phase_totals", Dict{String,Any}())
    phases = sort!(collect(union(keys(pa), keys(pb))))
    if !isempty(phases)
        println(repeat("─", 122))
        printstyled("  Phase Breakdown (Aggregate Seconds):\n"; bold=true)
        for p in phases
            va = Float64(get(pa, p, 0.0))
            vb = Float64(get(pb, p, 0.0))
            delta = vb - va
            pct = va > 1e-6 ? 100.0 * delta / va : 0.0
            col = delta > min_delta_s ? :red : (delta < -min_delta_s ? :green : :normal)
            printstyled(@sprintf("    %-16s : %8.4fs -> %8.4fs  (%+8.4fs, %+6.1f%%)\n",
                p, va, vb, delta, pct); color=col)
        end
    end

    # Per-Case Analysis with Noise-Spread Guardrail (Guardrail 3)
    notable = Tuple{String,Float64,Float64,Float64,String,Symbol}[]

    for name in common_names
        ca = cases_a[name]
        cb = cases_b[name]
        ta = Float64(get(ca, "time_compute", get(ca, "time_total", 0.0)))
        tb = Float64(get(cb, "time_compute", get(cb, "time_total", 0.0)))
        spread_a = Float64(get(ca, "time_spread", 0.0))
        spread_b = Float64(get(cb, "time_spread", 0.0))
        noise_floor = max(min_delta_s, spread_a, spread_b)

        delta = tb - ta
        ratio = (tb - ta) / max(ta, 1e-5)

        status_changed = ca["status"] != cb["status"]
        ma = get(ca, "metrics", Dict{String,Any}())
        mb = get(cb, "metrics", Dict{String,Any}())
        metrics_changed = ma != mb
        time_notable = abs(delta) >= noise_floor && abs(ratio) >= threshold

        if show_all || status_changed || metrics_changed || time_notable
            cause = _attribute_cause(ca, cb)
            ok_ca = Bool(get(ca, "ok", get(ca, "solved", true)))
            ok_cb = Bool(get(cb, "ok", get(cb, "solved", true)))
            kind = if !ok_cb && ok_ca
                :regression_fatal
            elseif ok_cb && !ok_ca
                :improvement_ok
            elseif delta > noise_floor && ratio >= threshold
                :regression_time
            elseif delta < -noise_floor && ratio <= -threshold
                :improvement_time
            else
                :neutral
            end
            push!(notable, (name, ta, tb, ratio * 100.0, cause, kind))
        end
    end

    sort!(notable, by=x -> -x[4])

    println(repeat("─", 122))
    if isempty(notable)
        printstyled("  No regressions or notable shifts exceeding noise floor ($(round(Int, threshold*100))%, min $(min_delta_s*1e3)ms).\n"; color=:green)
    else
        @printf("  %-36s %10s %10s %9s   %s\n", "Case", "Ref(ms)", "New(ms)", "Delta%", "Attribution (Phase / Metric / Alloc)")
        println("  " * repeat("─", 118))
        for (name, ta, tb, pct, cause, kind) in notable
            short_name = length(name) > 35 ? "…" * last(name, 34) : name
            col = kind in (:regression_fatal, :regression_time) ? :red :
                  (kind in (:improvement_ok, :improvement_time) ? :green : :yellow)
            printstyled(@sprintf("  %-36s %10.2f %10.2f %+8.1f%%   %s\n",
                short_name, ta * 1e3, tb * 1e3, pct, cause); color=col)
        end
    end
    if ra["code_signature"] != rb["code_signature"]
        println(repeat("─", 122))
        printstyled("  Tip: Run `Ablate.code_diff($id_a, $id_b)` to inspect the exact code changes between these runs.\n"; color=:light_black)
    end
    println(repeat("═", 122))
    return notable
end

function ablate_regressions(
    run_b=:last;
    against=:prev,
    suite::Union{Nothing,AbstractString}=nothing,
    threshold::Float64=0.15,
    min_delta_s::Float64=0.001,
    dir::AbstractString=pwd()
)
    notable = ablate_compare(against, run_b; suite=suite, threshold=threshold, min_delta_s=min_delta_s, dir=dir)
    return filter(x -> x[6] in (:regression_fatal, :regression_time), notable)
end

function ablate_trace(case_substr::AbstractString; suite::Union{Nothing,AbstractString}=nothing, dir::AbstractString=pwd())
    repo_root = find_repo_root(dir)
    ab_dir = ensure_ablation_dirs(repo_root)
    runs = load_runs(ab_dir)
    if suite !== nothing
        runs = filter(r -> r["suite"] == suite, runs)
    end

    println(repeat("─", 122))
    printstyled("TRACE FOR CASE MATCHING: \"$case_substr\"\n"; bold=true, color=:cyan)
    @printf("%-5s %-18s %-22s %-14s %11s %10s   %s\n",
        "Run", "Code Snapshot", "Label", "Status", "Compute(ms)", "Alloc(KB)", "Phases & Metrics")
    println(repeat("─", 122))

    history_rows = Dict{String,Any}[]
    for r in runs
        rid = Int(r["run_id"])
        for c in load_cases(ab_dir, rid)
            cname = String(c["name"])
            if occursin(case_substr, cname)
                t_comp = Float64(get(c, "time_compute", get(c, "time_total", 0.0))) * 1e3
                alloc_kb = Float64(get(c, "alloc_bytes", 0)) / 1024.0
                ph = get(c, "phases", get(c, "timings", Dict{String,Any}()))
                ph_parts = [@sprintf("%s=%.2fms", k, Float64(ph[k]) * 1e3) for k in sort!(collect(keys(ph))) if Float64(ph[k]) >= 1e-4]
                met = get(c, "metrics", Dict{String,Any}())
                met_parts = ["$k=$(met[k])" for k in sort!(collect(keys(met)))]
                details = join(vcat(ph_parts, met_parts), ", ")
                lbl = String(r["label"])
                lbl_s = length(lbl) > 21 ? first(lbl, 18) * "..." : lbl
                @printf("#%-4d %-18s %-22s %-14s %11.2f %10.1f   %s\n",
                    rid, r["code_signature"], lbl_s, c["status"], t_comp, alloc_kb, details)
                push!(history_rows, c)
            end
        end
    end
    println(repeat("─", 122))
    return history_rows
end

function _reconstruct_tree!(
    dest_dir::AbstractString,
    repo_root::AbstractString,
    commit::AbstractString,
    patch_hash::AbstractString,
    ab_dir::AbstractString
)
    tar_file = joinpath(dest_dir, "_archive.tar")
    run(Cmd(`git archive --format=tar -o $tar_file $commit`, dir=repo_root))
    run(Cmd(`tar -xf $tar_file`, dir=dest_dir))
    rm(tar_file; force=true)

    if !isempty(patch_hash)
        patch_path = joinpath(ab_dir, "patches", "$(patch_hash).diff")
        if isfile(patch_path)
            run(Cmd(`git apply --whitespace=nowarn $patch_path`, dir=dest_dir))
        end
    end
end

function ablate_code_diff(run_a=:prev, run_b=:last; dir::AbstractString=pwd())::String
    repo_root = find_repo_root(dir)
    ab_dir = ensure_ablation_dirs(repo_root)
    runs = load_runs(ab_dir)
    id_a = _resolve_run_id(run_a, runs, ab_dir)
    id_b = _resolve_run_id(run_b, runs, ab_dir)

    ra = runs[findfirst(r -> Int(r["run_id"]) == id_a, runs)]
    rb = runs[findfirst(r -> Int(r["run_id"]) == id_b, runs)]

    if ra["code_signature"] == rb["code_signature"]
        msg = "Runs #$id_a and #$id_b have the exact same code snapshot ($(ra["code_signature"]))."
        println(msg)
        return msg
    end

    diff_str = mktempdir() do tmp
        dir_a = joinpath(tmp, "run_$(id_a)")
        dir_b = joinpath(tmp, "run_$(id_b)")
        mkpath(dir_a)
        mkpath(dir_b)
        _reconstruct_tree!(dir_a, repo_root, String(ra["git_commit"]), String(ra["patch_hash"]), ab_dir)
        _reconstruct_tree!(dir_b, repo_root, String(rb["git_commit"]), String(rb["patch_hash"]), ab_dir)
        _, out = _read_cmd_safe(Cmd(`git diff --no-index -- run_$(id_a) run_$(id_b)`, dir=tmp))
        out
    end

    printstyled("═══ Code Diff: Run #$id_a ($(ra["code_signature"])) -> Run #$id_b ($(rb["code_signature"])) ═══\n"; bold=true, color=:cyan)
    for line in split(diff_str, '\n')
        if startswith(line, "+") && !startswith(line, "+++")
            printstyled(line, "\n"; color=:green)
        elseif startswith(line, "-") && !startswith(line, "---")
            printstyled(line, "\n"; color=:red)
        elseif startswith(line, "@@")
            printstyled(line, "\n"; color=:cyan)
        else
            println(line)
        end
    end
    return diff_str
end

function ablate_show_patch(run_spec=:last; dir::AbstractString=pwd())::String
    repo_root = find_repo_root(dir)
    ab_dir = ensure_ablation_dirs(repo_root)
    runs = load_runs(ab_dir)
    rid = _resolve_run_id(run_spec, runs, ab_dir)
    r = runs[findfirst(x -> Int(x["run_id"]) == rid, runs)]
    ph = String(r["patch_hash"])
    if isempty(ph)
        msg = "Run #$rid was on a clean git tree (commit $(r["git_commit"]))."
        println(msg)
        return msg
    end
    patch_path = joinpath(ab_dir, "patches", "$(ph).diff")
    content = read(patch_path, String)
    println(content)
    return content
end

function ablate_restore!(run_spec; dir::AbstractString=pwd(), dry_run::Bool=true)
    repo_root = find_repo_root(dir)
    ab_dir = ensure_ablation_dirs(repo_root)
    runs = load_runs(ab_dir)
    rid = _resolve_run_id(run_spec, runs, ab_dir)
    r = runs[findfirst(x -> Int(x["run_id"]) == rid, runs)]
    ph = String(r["patch_hash"])
    if isempty(ph)
        println("Run #$rid had no uncommitted patch (clean commit $(r["git_commit"])).")
        return true
    end
    patch_path = joinpath(ab_dir, "patches", "$(ph).diff")
    if dry_run
        ok, out = _read_cmd_safe(Cmd(`git apply --check $patch_path`, dir=repo_root))
        if ok
            printstyled("Dry-run succeeded: patch $(ph) from Run #$rid applies cleanly. Call `ablate_restore!($rid; dry_run=false)` to apply.\n"; color=:green)
        else
            printstyled("Dry-run conflict checking patch $(ph):\n$out\n"; color=:red)
        end
        return ok
    else
        run(Cmd(`git apply $patch_path`, dir=repo_root))
        printstyled("Applied patch $(ph) from Run #$rid to $(repo_root).\n"; bold=true, color=:green)
        return true
    end
end

function ablate_pin_baseline!(run_spec=:last; suite::Union{Nothing,AbstractString}=nothing, dir::AbstractString=pwd())
    repo_root = find_repo_root(dir)
    ab_dir = ensure_ablation_dirs(repo_root)
    runs = load_runs(ab_dir)
    rid = _resolve_run_id(run_spec, runs, ab_dir; suite=suite)
    r = runs[findfirst(x -> Int(x["run_id"]) == rid, runs)]
    st = String(r["suite"])
    baselines = load_baselines(ab_dir)
    baselines[st] = rid
    save_baselines(ab_dir, baselines)
    printstyled("Pinned Run #$rid (\"$(r["label"])\", $(r["code_signature"])) as baseline for suite '$st'.\n"; bold=true, color=:green)
    return rid
end

const history = ablate_history
const compare = ablate_compare
const regressions = ablate_regressions
const trace = ablate_trace
const code_diff = ablate_code_diff
const show_patch = ablate_show_patch
const restore! = ablate_restore!
const pin_baseline! = ablate_pin_baseline!

include("plots.jl")
include("remote.jl")

end # module Ablate
