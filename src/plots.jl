# ==============================================================================
# src/plots.jl — Zero-Dependency Publication SVG Plotting for Ablate.jl
# ==============================================================================

const _PALETTE = [
    ("#1473d1", ""),           # Royal Blue (solid)
    ("#d1382e", "6,4"),        # Crimson Red (dashed)
    ("#1f9e59", "2,3"),        # Forest Green (dotted)
    ("#9440c7", "8,3,2,3"),    # Amethyst Purple (dash-dot)
    ("#e68c19", "4,4"),        # Amber Orange (dashed)
    ("#19a6a6", "10,4"),       # Teal (long dash)
    ("#db3b88", "3,3"),        # Magenta
    ("#52606d", "")            # Slate Grey
]

function _xml_esc(s::AbstractString)::String
    s1 = replace(String(s), "&" => "&amp;")
    s2 = replace(s1, "<" => "&lt;")
    s3 = replace(s2, ">" => "&gt;")
    return replace(s3, "\"" => "&quot;")
end

function _save_plot(ab_dir::AbstractString, out::AbstractString, svg_str::AbstractString, title::AbstractString)::String
    base_path = replace(_default_plot_path(ab_dir, out), r"\.(svg|png)$"i => "")
    svg_path = base_path * ".svg"
    write(svg_path, svg_str)
    printstyled("📊 Saved $title:\n"; bold=true, color=:green)
    println("  - SVG: $svg_path")
    return svg_path
end

function _run_tag(run_ids::AbstractVector{<:Integer})::String
    length(run_ids) == 1 && return "run_$(run_ids[1])"
    length(run_ids) <= 12 && return "runs_" * join(run_ids, "_")
    return "runs_$(run_ids[1])_to_$(run_ids[end])_n$(length(run_ids))"
end

function _default_plot_path(ab_dir::AbstractString, filename::AbstractString)::String
    if dirname(filename) != ""
        mkpath(dirname(filename))
        return abspath(filename)
    end
    plots_dir = joinpath(ab_dir, "plots")
    mkpath(plots_dir)
    return joinpath(plots_dir, filename)
end

function _extract_case_val(c::Dict{String,Any}, metric::Symbol)::Float64
    ms = String(metric)
    if ms == "time_compute"
        return Float64(get(c, "time_compute", get(c, "time_total", 0.0)))
    elseif ms == "time_wall"
        return Float64(get(c, "time_wall", get(c, "time_total", 0.0)))
    elseif ms == "alloc_mb"
        return Float64(get(c, "alloc_bytes", 0)) / (1024.0 * 1024.0)
    elseif haskey(c, ms)
        return Float64(c[ms])
    elseif haskey(get(c, "phases", Dict{String,Any}()), ms)
        return Float64(c["phases"][ms])
    elseif haskey(get(c, "metrics", Dict{String,Any}()), ms)
        return Float64(c["metrics"][ms])
    else
        return 0.0
    end
end

function _format_pow10(e::Int)::String
    if e == 2
        return "100 s"
    elseif e == 1
        return "10 s"
    elseif e == 0
        return "1 s"
    elseif e == -1
        return "100 ms"
    elseif e == -2
        return "10 ms"
    elseif e == -3
        return "1 ms"
    elseif e == -4
        return "100 μs"
    elseif e == -5
        return "10 μs"
    elseif e == -6
        return "1 μs"
    elseif e == -7
        return "100 ns"
    else
        return "10^$(e) s"
    end
end

"""
    plot_cactus(run_specs=[:baseline, :last]; out="cactus.svg", suite=nothing, dir=pwd(), metric=:time_compute)

Generates a publication-ready 2-panel SVG:
- **Left Panel:** Cactus plot (Solved Count vs. Log-Scale Runtime per Instance).
- **Right Panel:** Cumulative Time vs. Solved Count with shaded area bands.
Returns the path to the generated SVG file.
"""
function plot_cactus(
    run_specs::AbstractVector=[:baseline, :last];
    out::Union{Nothing,AbstractString}=nothing,
    suite::Union{Nothing,AbstractString}=nothing,
    dir::AbstractString=pwd(),
    metric::Symbol=:time_compute,
    common_only::Bool=false,
    show_vbs::Bool=true,
    allow_split_mismatch::Bool=false
)::String
    repo_root = find_repo_root(dir)
    ab_dir = ensure_ablation_dirs(repo_root)
    runs = load_runs(ab_dir)
    isempty(runs) && error("No ablation runs recorded in $(ab_dir)")

    # Resolve unique run IDs preserving order
    run_ids = Int[]
    for spec in run_specs
        rid = _resolve_run_id(spec, runs, ab_dir; suite=suite)
        rid in run_ids || push!(run_ids, rid)
    end

    selected_runs = [runs[findfirst(x -> Int(x["run_id"]) == rid, runs)] for rid in run_ids]
    _check_split_compatibility!(selected_runs; allow_split_mismatch=allow_split_mismatch)

    all_run_cases = [load_cases(ab_dir, rid) for rid in run_ids]
    common_set = if common_only && !isempty(all_run_cases)
        intersect([Set(String(c["name"]) for c in cs) for cs in all_run_cases]...)
    else
        nothing
    end

    series = NamedTuple{(:run, :times, :color, :dash),Tuple{Dict{String,Any},Vector{Float64},String,String}}[]
    vbs_map = Dict{String,Float64}()
    for (idx, rid) in enumerate(run_ids)
        r = runs[findfirst(x -> Int(x["run_id"]) == rid, runs)]
        cases = all_run_cases[idx]
        if common_set !== nothing
            cases = filter(c -> String(c["name"]) in common_set, cases)
        end
        ok_cases = filter(c -> Bool(get(c, "ok", get(c, "solved", true))), cases)
        for c in ok_cases
            nm = String(c["name"])
            tv = max(_extract_case_val(c, metric), 1e-6)
            vbs_map[nm] = haskey(vbs_map, nm) ? min(vbs_map[nm], tv) : tv
        end
        ts = sort!([max(_extract_case_val(c, metric), 1e-6) for c in ok_cases])
        col, dash = _PALETTE[mod1(idx, length(_PALETTE))]
        push!(series, (run=r, times=ts, color=col, dash=dash))
    end
    vbs_times = (show_vbs && length(run_ids) >= 2 && !isempty(vbs_map)) ? sort!(collect(values(vbs_map))) : Float64[]

    W, H = 1200, 520
    pad_l1, pad_r1, pad_t, pad_b = 80.0, 40.0, 55.0, 65.0
    pw = (W - pad_l1 - pad_r1 - 90.0) / 2.0
    ph = H - pad_t - pad_b
    x1_0, y1_0 = pad_l1, pad_t
    x2_0, y2_0 = pad_l1 + pw + 90.0, pad_t

    max_n = maximum( max(1, length(s.times)) for s in series )
    all_ts = vcat([s.times for s in series]...)
    min_t = isempty(all_ts) ? 1e-4 : minimum(all_ts)
    max_t = isempty(all_ts) ? 1.0 : maximum(all_ts)
    exp_min = floor(Int, log10(min_t))
    exp_max = max(exp_min + 1, ceil(Int, log10(max_t * 1.25)))

    max_cum = maximum( isempty(s.times) ? 1e-3 : sum(s.times) for s in series ) * 1.10

    x_map1(i) = x1_0 + (max_n <= 1 ? pw / 2 : (i - 1) / (max_n - 1) * pw)
    y_map1(t) = y1_0 + ph - ((log10(clamp(t, 10.0^exp_min, 10.0^exp_max)) - exp_min) / (exp_max - exp_min)) * ph

    x_map2(i) = x2_0 + (max_n <= 1 ? pw / 2 : (i - 1) / (max_n - 1) * pw)
    y_map2(ct) = y2_0 + ph - clamp(ct / max_cum, 0.0, 1.0) * ph

    buf = IOBuffer()
    println(buf, """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $W $H" width="$W" height="$H" font-family="Helvetica, Arial, DejaVu Sans, sans-serif">""")
    println(buf, """<rect width="100%" height="100%" fill="#ffffff"/>""")

    # Panel 1 Grid & Axes (Log-Scale Cactus)
    println(buf, """<text x="$(x1_0 + pw/2)" y="32" text-anchor="middle" font-size="15" font-weight="bold" fill="#1f2933">Cactus Plot (Log-Scale Runtime per Instance)</text>""")
    for e in exp_min:exp_max
        yy = y_map1(10.0^e)
        println(buf, """<line x1="$x1_0" y1="$yy" x2="$(x1_0 + pw)" y2="$yy" stroke="#e4e7eb" stroke-dasharray="4,4" stroke-width="1"/>""")
        println(buf, """<text x="$(x1_0 - 10)" y="$(yy + 4)" text-anchor="end" font-size="11" fill="#52606d">$(_format_pow10(e))</text>""")
    end

    n_xticks = min(max_n, 6)
    for k in 0:(n_xticks - 1)
        idx = max_n <= 1 ? 1 : round(Int, 1 + k * (max_n - 1) / max(1, n_xticks - 1))
        xx = x_map1(idx)
        println(buf, """<line x1="$xx" y1="$y1_0" x2="$xx" y2="$(y1_0 + ph)" stroke="#e4e7eb" stroke-dasharray="4,4" stroke-width="1"/>""")
        println(buf, """<text x="$xx" y="$(y1_0 + ph + 22)" text-anchor="middle" font-size="11" fill="#52606d">$idx</text>""")
    end
    println(buf, """<line x1="$x1_0" y1="$(y1_0 + ph)" x2="$(x1_0 + pw)" y2="$(y1_0 + ph)" stroke="#323f4b" stroke-width="1.4"/>""")
    println(buf, """<line x1="$x1_0" y1="$y1_0" x2="$x1_0" y2="$(y1_0 + ph)" stroke="#323f4b" stroke-width="1.4"/>""")
    println(buf, """<text x="$(x1_0 + pw/2)" y="$(H - 16)" text-anchor="middle" font-size="13" fill="#323f4b">Solved Instances (Count)</text>""")
    println(buf, """<text x="22" y="$(y1_0 + ph/2)" text-anchor="middle" font-size="13" fill="#323f4b" transform="rotate(-90, 22, $(y1_0 + ph/2))">Instance Runtime (log scale)</text>""")

    # Panel 2 Grid & Axes (Cumulative Time)
    println(buf, """<text x="$(x2_0 + pw/2)" y="32" text-anchor="middle" font-size="15" font-weight="bold" fill="#1f2933">Cumulative Compute Time</text>""")
    for k in 0:5
        val = max_cum * k / 5.0
        yy = y_map2(val)
        println(buf, """<line x1="$x2_0" y1="$yy" x2="$(x2_0 + pw)" y2="$yy" stroke="#e4e7eb" stroke-dasharray="4,4" stroke-width="1"/>""")
        lbl_y = max_cum < 0.5 ? @sprintf("%.1f ms", val * 1e3) : @sprintf("%.2f s", val)
        println(buf, """<text x="$(x2_0 - 10)" y="$(yy + 4)" text-anchor="end" font-size="11" fill="#52606d">$lbl_y</text>""")
    end
    for k in 0:(n_xticks - 1)
        idx = max_n <= 1 ? 1 : round(Int, 1 + k * (max_n - 1) / max(1, n_xticks - 1))
        xx = x_map2(idx)
        println(buf, """<line x1="$xx" y1="$y2_0" x2="$xx" y2="$(y2_0 + ph)" stroke="#e4e7eb" stroke-dasharray="4,4" stroke-width="1"/>""")
        println(buf, """<text x="$xx" y="$(y2_0 + ph + 22)" text-anchor="middle" font-size="11" fill="#52606d">$idx</text>""")
    end
    println(buf, """<line x1="$x2_0" y1="$(y2_0 + ph)" x2="$(x2_0 + pw)" y2="$(y2_0 + ph)" stroke="#323f4b" stroke-width="1.4"/>""")
    println(buf, """<line x1="$x2_0" y1="$y2_0" x2="$x2_0" y2="$(y2_0 + ph)" stroke="#323f4b" stroke-width="1.4"/>""")
    println(buf, """<text x="$(x2_0 + pw/2)" y="$(H - 16)" text-anchor="middle" font-size="13" fill="#323f4b">Solved Instances (Count)</text>""")
    println(buf, """<text x="$(x2_0 - 62)" y="$(y2_0 + ph/2)" text-anchor="middle" font-size="13" fill="#323f4b" transform="rotate(-90, $(x2_0 - 62), $(y2_0 + ph/2))">Cumulative Time</text>""")

    # Plot curves on both panels
    for s in series
        isempty(s.times) && continue
        pts1 = join([@sprintf("%.2f,%.2f", x_map1(i), y_map1(t)) for (i, t) in enumerate(s.times)], " ")
        dash_attr = isempty(s.dash) ? "" : """ stroke-dasharray="$(s.dash)" """
        println(buf, """<polyline fill="none" stroke="$(s.color)" stroke-width="2.5"$dash_attr points="$pts1"/>""")
        if length(s.times) <= 40
            for (i, t) in enumerate(s.times)
                println(buf, """<circle cx="$(x_map1(i))" cy="$(y_map1(t))" r="2.8" fill="$(s.color)"/>""")
            end
        end

        cum_ts = cumsum(s.times)
        pts2 = [@sprintf("%.2f,%.2f", x_map2(i), y_map2(ct)) for (i, ct) in enumerate(cum_ts)]
        poly_pts = @sprintf("%.2f,%.2f ", x_map2(1), y_map2(0.0)) * join(pts2, " ") * @sprintf(" %.2f,%.2f", x_map2(length(cum_ts)), y_map2(0.0))
        println(buf, """<polygon fill="$(s.color)" fill-opacity="0.08" points="$poly_pts"/>""")
        println(buf, """<polyline fill="none" stroke="$(s.color)" stroke-width="2.5"$dash_attr points="$(join(pts2, " "))"/>""")
    end

    if !isempty(vbs_times)
        pts_v1 = join([@sprintf("%.2f,%.2f", x_map1(i), y_map1(t)) for (i, t) in enumerate(vbs_times)], " ")
        println(buf, """<polyline fill="none" stroke="#1f2933" stroke-width="1.8" stroke-dasharray="2,3" points="$pts_v1"/>""")
        cum_vbs = cumsum(vbs_times)
        pts_v2 = join([@sprintf("%.2f,%.2f", x_map2(i), y_map2(ct)) for (i, ct) in enumerate(cum_vbs)], " ")
        println(buf, """<polyline fill="none" stroke="#1f2933" stroke-width="1.8" stroke-dasharray="2,3" points="$pts_v2"/>""")
    end

    # Legends
    n_leg = length(series) + (isempty(vbs_times) ? 0 : 1)
    leg_h = 14 + 22 * n_leg
    println(buf, """<rect x="$(x1_0 + 12)" y="$(y1_0 + 10)" width="265" height="$leg_h" rx="4" fill="#ffffff" fill-opacity="0.92" stroke="#cbd2d9" stroke-width="1"/>""")
    println(buf, """<rect x="$(x2_0 + 12)" y="$(y2_0 + 10)" width="265" height="$leg_h" rx="4" fill="#ffffff" fill-opacity="0.92" stroke="#cbd2d9" stroke-width="1"/>""")

    for (idx, s) in enumerate(series)
        ly = y1_0 + 18 + (idx - 1) * 22
        dash_attr = isempty(s.dash) ? "" : """ stroke-dasharray="$(s.dash)" """
        rid = Int(s.run["run_id"])
        lbl = _xml_esc(String(s.run["label"]))
        n_ok = length(s.times)
        n_tot = Int(s.run["n_total"])
        tot_t = isempty(s.times) ? 0.0 : sum(s.times)
        t_str = tot_t < 0.5 ? @sprintf("%.1fms", tot_t * 1e3) : @sprintf("%.2fs", tot_t)

        println(buf, """<line x1="$(x1_0 + 20)" y1="$(ly + 6)" x2="$(x1_0 + 46)" y2="$(ly + 6)" stroke="$(s.color)" stroke-width="2.5"$dash_attr/>""")
        println(buf, """<text x="$(x1_0 + 54)" y="$(ly + 10)" font-size="11" fill="#1f2933">#$rid: $lbl ($n_ok/$n_tot)</text>""")

        println(buf, """<line x1="$(x2_0 + 20)" y1="$(ly + 6)" x2="$(x2_0 + 46)" y2="$(ly + 6)" stroke="$(s.color)" stroke-width="2.5"$dash_attr/>""")
        println(buf, """<text x="$(x2_0 + 54)" y="$(ly + 10)" font-size="11" fill="#1f2933">#$rid: $lbl ($t_str)</text>""")
    end
    if !isempty(vbs_times)
        ly = y1_0 + 18 + length(series) * 22
        tot_vbs = sum(vbs_times)
        vbs_str = tot_vbs < 0.5 ? @sprintf("%.1fms", tot_vbs * 1e3) : @sprintf("%.2fs", tot_vbs)
        println(buf, """<line x1="$(x1_0 + 20)" y1="$(ly + 6)" x2="$(x1_0 + 46)" y2="$(ly + 6)" stroke="#1f2933" stroke-width="1.8" stroke-dasharray="2,3"/>""")
        println(buf, """<text x="$(x1_0 + 54)" y="$(ly + 10)" font-size="11" font-weight="bold" fill="#1f2933">VBS: Virtual Best ($(length(vbs_times)) solved)</text>""")
        println(buf, """<line x1="$(x2_0 + 20)" y1="$(ly + 6)" x2="$(x2_0 + 46)" y2="$(ly + 6)" stroke="#1f2933" stroke-width="1.8" stroke-dasharray="2,3"/>""")
        println(buf, """<text x="$(x2_0 + 54)" y="$(ly + 10)" font-size="11" font-weight="bold" fill="#1f2933">VBS: Virtual Best ($vbs_str)</text>""")
    end

    println(buf, "</svg>")
    out_name = out === nothing ? "cactus_$(_run_tag(run_ids)).svg" : out
    return _save_plot(ab_dir, out_name, String(take!(buf)), "Cactus plot")
end

"""
    plot_scatter(run_a=:baseline, run_b=:last; out="scatter.svg", suite=nothing, dir=pwd(), metric=:time_compute)

Generates a Log-Log Head-to-Head Scatter Plot comparing per-case runtime in `run_a` (x-axis)
vs `run_b` (y-axis), with 1x, 2x, and 10x guide bands and automatic outlier labels.
"""
function plot_scatter(
    run_a=:baseline,
    run_b=:last;
    out::Union{Nothing,AbstractString}=nothing,
    suite::Union{Nothing,AbstractString}=nothing,
    dir::AbstractString=pwd(),
    metric::Symbol=:time_compute
)::String
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

    pts = Tuple{String,Float64,Float64}[]
    for name in common
        ta = max(_extract_case_val(cases_a[name], metric), 1e-6)
        tb = max(_extract_case_val(cases_b[name], metric), 1e-6)
        push!(pts, (name, ta, tb))
    end

    W, H = 680, 640
    pad_l, pad_r, pad_t, pad_b = 85.0, 45.0, 60.0, 75.0
    pw, ph = W - pad_l - pad_r, H - pad_t - pad_b

    all_vals = vcat([p[2] for p in pts], [p[3] for p in pts])
    min_v = isempty(all_vals) ? 1e-4 : minimum(all_vals) * 0.7
    max_v = isempty(all_vals) ? 1.0 : maximum(all_vals) * 1.4
    exp_min = floor(Int, log10(min_v))
    exp_max = max(exp_min + 1, ceil(Int, log10(max_v)))

    x_map(t) = pad_l + ((log10(clamp(t, 10.0^exp_min, 10.0^exp_max)) - exp_min) / (exp_max - exp_min)) * pw
    y_map(t) = pad_t + ph - ((log10(clamp(t, 10.0^exp_min, 10.0^exp_max)) - exp_min) / (exp_max - exp_min)) * ph

    buf = IOBuffer()
    println(buf, """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $W $H" width="$W" height="$H" font-family="Helvetica, Arial, DejaVu Sans, sans-serif">""")
    println(buf, """<rect width="100%" height="100%" fill="#ffffff"/>""")
    println(buf, """<text x="$(pad_l + pw/2)" y="32" text-anchor="middle" font-size="15" font-weight="bold" fill="#1f2933">Head-to-Head Runtime: Run #$id_a vs Run #$id_b</text>""")

    for e in exp_min:exp_max
        v = 10.0^e
        xx, yy = x_map(v), y_map(v)
        lbl = _format_pow10(e)
        println(buf, """<line x1="$xx" y1="$pad_t" x2="$xx" y2="$(pad_t + ph)" stroke="#e4e7eb" stroke-dasharray="4,4" stroke-width="1"/>""")
        println(buf, """<line x1="$pad_l" y1="$yy" x2="$(pad_l + pw)" y2="$yy" stroke="#e4e7eb" stroke-dasharray="4,4" stroke-width="1"/>""")
        println(buf, """<text x="$xx" y="$(pad_t + ph + 22)" text-anchor="middle" font-size="11" fill="#52606d">$lbl</text>""")
        println(buf, """<text x="$(pad_l - 10)" y="$(yy + 4)" text-anchor="end" font-size="11" fill="#52606d">$lbl</text>""")
    end

    # 1x diagonal & 2x guide bands
    println(buf, """<line x1="$pad_l" y1="$(pad_t + ph)" x2="$(pad_l + pw)" y2="$pad_t" stroke="#323f4b" stroke-width="1.5"/>""")
    for mult in (2.0, 0.5)
        t_start = max(10.0^exp_min, (10.0^exp_min) / mult)
        t_end = min(10.0^exp_max, (10.0^exp_max) / mult)
        if t_end > t_start
            println(buf, """<line x1="$(x_map(t_start))" y1="$(y_map(t_start * mult))" x2="$(x_map(t_end))" y2="$(y_map(t_end * mult))" stroke="#9aa5b1" stroke-dasharray="5,5" stroke-width="1"/>""")
        end
    end

    println(buf, """<line x1="$pad_l" y1="$(pad_t + ph)" x2="$(pad_l + pw)" y2="$(pad_t + ph)" stroke="#323f4b" stroke-width="1.4"/>""")
    println(buf, """<line x1="$pad_l" y1="$pad_t" x2="$pad_l" y2="$(pad_t + ph)" stroke="#323f4b" stroke-width="1.4"/>""")
    println(buf, """<text x="$(pad_l + pw/2)" y="$(H - 20)" text-anchor="middle" font-size="13" fill="#323f4b">Ref Run #$id_a: $(_xml_esc(String(ra["label"])))</text>""")
    println(buf, """<text x="22" y="$(pad_t + ph/2)" text-anchor="middle" font-size="13" fill="#323f4b" transform="rotate(-90, 22, $(pad_t + ph/2))">New Run #$id_b: $(_xml_esc(String(rb["label"]))) (lower = faster)</text>""")

    for (name, ta, tb) in pts
        xx, yy = x_map(ta), y_map(tb)
        ratio = tb / ta
        col = ratio > 1.20 ? "#d1382e" : (ratio < 0.83 ? "#1f9e59" : "#1473d1")
        println(buf, """<circle cx="$xx" cy="$yy" r="4.2" fill="$col" fill-opacity="0.80" stroke="#ffffff" stroke-width="0.8"/>""")
    end

    # Collision-free outlier labels (prioritize largest relative ratios, max 8 labels)
    outliers = filter(p -> (p[3] / p[2] > 1.5 || p[3] / p[2] < 0.67) && abs(p[3] - p[2]) >= 1e-3, pts)
    sort!(outliers; by=p -> abs(log(p[3] / p[2])), rev=true)
    placed_lbls = Tuple{Float64,Float64}[]
    for (name, ta, tb) in outliers
        length(placed_lbls) >= 8 && break
        xx, yy = x_map(ta), y_map(tb)
        lx, ly = xx + 6.0, yy - 4.0
        lx > pad_l + pw - 140.0 && (lx = xx - 140.0)
        any(p -> abs(lx - p[1]) < 145.0 && abs(ly - p[2]) < 15.0, placed_lbls) && continue
        push!(placed_lbls, (lx, ly))
        ratio = tb / ta
        col = ratio > 1.20 ? "#d1382e" : "#1f9e59"
        short_n = _xml_esc(basename(name))
        println(buf, """<text x="$lx" y="$ly" font-size="9.5" fill="$col">$short_n</text>""")
    end

    println(buf, "</svg>")
    out_name = out === nothing ? "scatter_$(id_a)_vs_$(id_b).svg" : out
    return _save_plot(ab_dir, out_name, String(take!(buf)), "Scatter plot")
end

"""
    plot_performance_profile(run_specs=[:baseline, :last]; out="perf_profile.svg", suite=nothing, dir=pwd(), metric=:time_compute, tau_max=16.0)

Generates a 2-Panel Dolan–Moré Performance Profile comparing multiple solvers simultaneously
while preserving paired instance-by-instance matching:
- **Left Panel (Near-Optimal Zoom, τ ∈ [1x, 4x]):** Shows the exact win rate at τ = 1x and
  the fraction of problems solved within 1.25x, 1.5x, 2x, 3x, and 4x of the Virtual Best Solver.
- **Right Panel (Full Tail Robustness, τ ∈ [1x, tau_max] log scale):** Shows convergence to 100%
  and exposes tail slowdowns.
"""
function plot_performance_profile(
    run_specs::AbstractVector=[:baseline, :last];
    out::Union{Nothing,AbstractString}=nothing,
    suite::Union{Nothing,AbstractString}=nothing,
    dir::AbstractString=pwd(),
    metric::Symbol=:time_compute,
    tau_max::Float64=32.0
)::String
    repo_root = find_repo_root(dir)
    ab_dir = ensure_ablation_dirs(repo_root)
    runs = load_runs(ab_dir)
    isempty(runs) && error("No ablation runs recorded in $(ab_dir)")

    run_ids = Int[]
    for spec in run_specs
        rid = _resolve_run_id(spec, runs, ab_dir; suite=suite)
        rid in run_ids || push!(run_ids, rid)
    end

    case_maps = [Dict(String(c["name"]) => c for c in load_cases(ab_dir, rid)) for rid in run_ids]
    all_names = sort!(collect(union([keys(cm) for cm in case_maps]...)))
    n_probs = max(1, length(all_names))

    # Virtual Best Solver time per instance
    vbs_t = Dict{String,Float64}()
    for nm in all_names
        best = Inf
        for cm in case_maps
            if haskey(cm, nm) && Bool(get(cm[nm], "ok", get(cm[nm], "solved", true)))
                best = min(best, max(_extract_case_val(cm[nm], metric), 1e-6))
            end
        end
        vbs_t[nm] = best
    end

    # Compute sorted performance ratios r_{p,s} = t_{p,s} / vbs_t[p] for each solver
    profiles = NamedTuple{(:run, :ratios, :win_pct, :within2x_pct, :color, :dash),Tuple{Dict{String,Any},Vector{Float64},Float64,Float64,String,String}}[]
    for (idx, rid) in enumerate(run_ids)
        r = runs[findfirst(x -> Int(x["run_id"]) == rid, runs)]
        cm = case_maps[idx]
        ratios = Float64[]
        for nm in all_names
            if haskey(cm, nm) && Bool(get(cm[nm], "ok", get(cm[nm], "solved", true))) && isfinite(vbs_t[nm])
                t_val = max(_extract_case_val(cm[nm], metric), 1e-6)
                push!(ratios, max(1.0, t_val / vbs_t[nm]))
            end
        end
        sort!(ratios)
        win_pct = 100.0 * count(x -> x <= 1.0001, ratios) / n_probs
        w2_pct = 100.0 * count(x -> x <= 2.0, ratios) / n_probs
        col, dash = _PALETTE[mod1(idx, length(_PALETTE))]
        push!(profiles, (run=r, ratios=ratios, win_pct=win_pct, within2x_pct=w2_pct, color=col, dash=dash))
    end

    W, H = 1200, 520
    pad_l1, pad_r1, pad_t, pad_b = 75.0, 35.0, 55.0, 65.0
    pw = (W - pad_l1 - pad_r1 - 85.0) / 2.0
    ph = H - pad_t - pad_b
    x1_0, y1_0 = pad_l1, pad_t
    x2_0, y2_0 = pad_l1 + pw + 85.0, pad_t

    # Left panel: linear zoom τ ∈ [1.0, 4.0]
    tau_zoom = 4.0
    x_map1(tau) = x1_0 + clamp((tau - 1.0) / (tau_zoom - 1.0), 0.0, 1.0) * pw
    y_map(pct) = y1_0 + ph - clamp(pct / 100.0, 0.0, 1.0) * ph

    # Right panel: log2 scale τ ∈ [1.0, tau_max]
    log2_max = max(2.0, log2(tau_max))
    x_map2(tau) = x2_0 + clamp(log2(max(1.0, tau)) / log2_max, 0.0, 1.0) * pw

    buf = IOBuffer()
    println(buf, """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $W $H" width="$W" height="$H" font-family="Helvetica, Arial, DejaVu Sans, sans-serif">""")
    println(buf, """<rect width="100%" height="100%" fill="#ffffff"/>""")

    # Panel 1 Grid
    println(buf, """<text x="$(x1_0 + pw/2)" y="32" text-anchor="middle" font-size="15" font-weight="bold" fill="#1f2933">Dolan–Moré Profile: Near-Optimal Region (τ ≤ 4x)</text>""")
    for pct in 0:20:100
        yy = y_map(pct)
        println(buf, """<line x1="$x1_0" y1="$yy" x2="$(x1_0 + pw)" y2="$yy" stroke="#e4e7eb" stroke-dasharray="4,4" stroke-width="1"/>""")
        println(buf, """<text x="$(x1_0 - 10)" y="$(yy + 4)" text-anchor="end" font-size="11" fill="#52606d">$(pct)%</text>""")
    end
    for tau in (1.0, 1.25, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0)
        xx = x_map1(tau)
        println(buf, """<line x1="$xx" y1="$y1_0" x2="$xx" y2="$(y1_0 + ph)" stroke="#e4e7eb" stroke-dasharray="4,4" stroke-width="1"/>""")
        lbl = tau == round(tau) ? "$(Int(tau))x" : "$(tau)x"
        println(buf, """<text x="$xx" y="$(y1_0 + ph + 22)" text-anchor="middle" font-size="11" fill="#52606d">$lbl</text>""")
    end
    println(buf, """<line x1="$x1_0" y1="$(y1_0 + ph)" x2="$(x1_0 + pw)" y2="$(y1_0 + ph)" stroke="#323f4b" stroke-width="1.4"/>""")
    println(buf, """<line x1="$x1_0" y1="$y1_0" x2="$x1_0" y2="$(y1_0 + ph)" stroke="#323f4b" stroke-width="1.4"/>""")
    println(buf, """<text x="$(x1_0 + pw/2)" y="$(H - 16)" text-anchor="middle" font-size="13" fill="#323f4b">Performance Ratio τ = t_solver / t_best (linear scale)</text>""")
    println(buf, """<text x="22" y="$(y1_0 + ph/2)" text-anchor="middle" font-size="13" fill="#323f4b" transform="rotate(-90, 22, $(y1_0 + ph/2))">Solved within Factor τ (%)</text>""")

    # Panel 2 Grid
    println(buf, """<text x="$(x2_0 + pw/2)" y="32" text-anchor="middle" font-size="15" font-weight="bold" fill="#1f2933">Dolan–Moré Profile: Tail Robustness (Log Scale)</text>""")
    for pct in 0:20:100
        yy = y_map(pct)
        println(buf, """<line x1="$x2_0" y1="$yy" x2="$(x2_0 + pw)" y2="$yy" stroke="#e4e7eb" stroke-dasharray="4,4" stroke-width="1"/>""")
        println(buf, """<text x="$(x2_0 - 10)" y="$(yy + 4)" text-anchor="end" font-size="11" fill="#52606d">$(pct)%</text>""")
    end
    for k in 0:round(Int, log2_max)
        tau = 2.0^k
        xx = x_map2(tau)
        println(buf, """<line x1="$xx" y1="$y2_0" x2="$xx" y2="$(y2_0 + ph)" stroke="#e4e7eb" stroke-dasharray="4,4" stroke-width="1"/>""")
        println(buf, """<text x="$xx" y="$(y2_0 + ph + 22)" text-anchor="middle" font-size="11" fill="#52606d">$(Int(round(tau)))x</text>""")
    end
    println(buf, """<line x1="$x2_0" y1="$(y2_0 + ph)" x2="$(x2_0 + pw)" y2="$(y2_0 + ph)" stroke="#323f4b" stroke-width="1.4"/>""")
    println(buf, """<line x1="$x2_0" y1="$y2_0" x2="$x2_0" y2="$(y2_0 + ph)" stroke="#323f4b" stroke-width="1.4"/>""")
    println(buf, """<text x="$(x2_0 + pw/2)" y="$(H - 16)" text-anchor="middle" font-size="13" fill="#323f4b">Performance Ratio τ = t_solver / t_best (log₂ scale)</text>""")
    println(buf, """<text x="$(x2_0 - 55)" y="$(y2_0 + ph/2)" text-anchor="middle" font-size="13" fill="#323f4b" transform="rotate(-90, $(x2_0 - 55), $(y2_0 + ph/2))">Solved within Factor τ (%)</text>""")

    # Step function builder for ECDF
    for p in profiles
        isempty(p.ratios) && continue
        dash_attr = isempty(p.dash) ? "" : """ stroke-dasharray="$(p.dash)" """

        # Subsample up to 250 quantile points for crisp, lightweight SVG polylines
        n_r = length(p.ratios)
        idxs = unique(round.(Int, range(1, n_r, length=min(n_r, 250))))

        pts1 = String[@sprintf("%.2f,%.2f", x_map1(1.0), y_map(p.win_pct))]
        pts2 = String[@sprintf("%.2f,%.2f", x_map2(1.0), y_map(p.win_pct))]
        prev_pct = p.win_pct
        for i in idxs
            r_val = p.ratios[i]
            pct = 100.0 * i / n_probs
            if r_val <= tau_zoom
                push!(pts1, @sprintf("%.2f,%.2f", x_map1(r_val), y_map(prev_pct)))
                push!(pts1, @sprintf("%.2f,%.2f", x_map1(r_val), y_map(pct)))
            end
            if r_val <= tau_max
                push!(pts2, @sprintf("%.2f,%.2f", x_map2(r_val), y_map(prev_pct)))
                push!(pts2, @sprintf("%.2f,%.2f", x_map2(r_val), y_map(pct)))
            end
            prev_pct = pct
        end
        pct_at_zoom = 100.0 * count(x -> x <= tau_zoom, p.ratios) / n_probs
        pct_at_max = 100.0 * count(x -> x <= tau_max, p.ratios) / n_probs
        push!(pts1, @sprintf("%.2f,%.2f", x_map1(tau_zoom), y_map(pct_at_zoom)))
        push!(pts2, @sprintf("%.2f,%.2f", x_map2(tau_max), y_map(pct_at_max)))

        println(buf, """<polyline fill="none" stroke="$(p.color)" stroke-width="2.5"$dash_attr points="$(join(pts1, " "))"/>""")
        println(buf, """<polyline fill="none" stroke="$(p.color)" stroke-width="2.5"$dash_attr points="$(join(pts2, " "))"/>""")
    end

    # Legend (bottom-right of both panels)
    leg_w, leg_h = 315.0, 14.0 + 22.0 * length(profiles)
    lx1, ly1 = x1_0 + pw - leg_w - 12.0, y1_0 + ph - leg_h - 12.0
    lx2, ly2 = x2_0 + pw - leg_w - 12.0, y2_0 + ph - leg_h - 12.0
    println(buf, """<rect x="$lx1" y="$ly1" width="$leg_w" height="$leg_h" rx="4" fill="#ffffff" fill-opacity="0.93" stroke="#cbd2d9" stroke-width="1"/>""")
    println(buf, """<rect x="$lx2" y="$ly2" width="$leg_w" height="$leg_h" rx="4" fill="#ffffff" fill-opacity="0.93" stroke="#cbd2d9" stroke-width="1"/>""")

    for (idx, p) in enumerate(profiles)
        yy1 = ly1 + 8.0 + (idx - 1) * 22.0
        yy2 = ly2 + 8.0 + (idx - 1) * 22.0
        dash_attr = isempty(p.dash) ? "" : """ stroke-dasharray="$(p.dash)" """
        rid = Int(p.run["run_id"])
        lbl = _xml_esc(String(p.run["label"]))
        s_txt = @sprintf("#%d: %s (Wins: %.1f%%, ≤2x: %.1f%%)", rid, lbl, p.win_pct, p.within2x_pct)

        println(buf, """<line x1="$(lx1 + 10)" y1="$(yy1 + 6)" x2="$(lx1 + 34)" y2="$(yy1 + 6)" stroke="$(p.color)" stroke-width="2.5"$dash_attr/>""")
        println(buf, """<text x="$(lx1 + 42)" y="$(yy1 + 10)" font-size="10.5" fill="#1f2933">$s_txt</text>""")

        println(buf, """<line x1="$(lx2 + 10)" y1="$(yy2 + 6)" x2="$(lx2 + 34)" y2="$(yy2 + 6)" stroke="$(p.color)" stroke-width="2.5"$dash_attr/>""")
        println(buf, """<text x="$(lx2 + 42)" y="$(yy2 + 10)" font-size="10.5" fill="#1f2933">$s_txt</text>""")
    end

    println(buf, "</svg>")
    out_name = out === nothing ? "perf_profile_$(_run_tag(run_ids)).svg" : out
    return _save_plot(ab_dir, out_name, String(take!(buf)), "Dolan–Moré Performance Profile")
end

"""
    plot_speedup(ref_spec, run_specs; out="speedup.svg", suite=nothing, dir=pwd(), metric=:time_compute)

Generates a Paired Per-Instance Speedup Quantile Plot comparing multiple solver runs against
a fixed reference run `ref_spec` (`speedup(p) = t_ref(p) / t_solver(p)`), sorted from worst
regression to largest speedup across percentiles (0% to 100%).
"""
function plot_speedup(
    ref_spec,
    run_specs::AbstractVector;
    out::Union{Nothing,AbstractString}=nothing,
    suite::Union{Nothing,AbstractString}=nothing,
    dir::AbstractString=pwd(),
    metric::Symbol=:time_compute
)::String
    repo_root = find_repo_root(dir)
    ab_dir = ensure_ablation_dirs(repo_root)
    runs = load_runs(ab_dir)
    isempty(runs) && error("No ablation runs recorded in $(ab_dir)")

    ref_id = _resolve_run_id(ref_spec, runs, ab_dir; suite=suite)
    ref_run = runs[findfirst(x -> Int(x["run_id"]) == ref_id, runs)]
    target_suite = suite === nothing ? String(ref_run["suite"]) : String(suite)
    ref_cases = Dict(String(c["name"]) => c for c in load_cases(ab_dir, ref_id))

    run_ids = Int[]
    for spec in run_specs
        rid = _resolve_run_id(spec, runs, ab_dir; suite=target_suite)
        (rid == ref_id || rid in run_ids) || push!(run_ids, rid)
    end

    curves = NamedTuple{(:run, :speedups, :gm, :faster_pct, :color, :dash),Tuple{Dict{String,Any},Vector{Float64},Float64,Float64,String,String}}[]
    for (idx, rid) in enumerate(run_ids)
        r = runs[findfirst(x -> Int(x["run_id"]) == rid, runs)]
        cm = Dict(String(c["name"]) => c for c in load_cases(ab_dir, rid))
        common = intersect(keys(ref_cases), keys(cm))
        sp = Float64[]
        for nm in common
            if Bool(get(ref_cases[nm], "ok", true)) && Bool(get(cm[nm], "ok", true))
                t_ref = max(_extract_case_val(ref_cases[nm], metric), 1e-6)
                t_cur = max(_extract_case_val(cm[nm], metric), 1e-6)
                push!(sp, t_ref / t_cur)
            end
        end
        sort!(sp)
        gm = isempty(sp) ? 1.0 : exp(mean(log.(sp)))
        faster_pct = isempty(sp) ? 0.0 : 100.0 * count(>(1.0), sp) / length(sp)
        col, dash = _PALETTE[mod1(idx, length(_PALETTE))]
        push!(curves, (run=r, speedups=sp, gm=gm, faster_pct=faster_pct, color=col, dash=dash))
    end

    W, H = 860, 520
    pad_l, pad_r, pad_t, pad_b = 85.0, 40.0, 55.0, 65.0
    pw, ph = W - pad_l - pad_r, H - pad_t - pad_b

    # Log10 scale from 0.1x (-1) to 10x (+1) or auto-expanded
    all_sp = vcat([c.speedups for c in curves]...)
    min_sp = isempty(all_sp) ? 0.25 : clamp(minimum(all_sp), 0.02, 0.4)
    max_sp = isempty(all_sp) ? 4.0 : clamp(maximum(all_sp), 2.5, 50.0)
    l_min = log10(min_sp * 0.9)
    l_max = log10(max_sp * 1.1)

    x_map(pct) = pad_l + clamp(pct / 100.0, 0.0, 1.0) * pw
    y_map(sp) = pad_t + ph - clamp((log10(clamp(sp, 10.0^l_min, 10.0^l_max)) - l_min) / (l_max - l_min), 0.0, 1.0) * ph

    buf = IOBuffer()
    println(buf, """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $W $H" width="$W" height="$H" font-family="Helvetica, Arial, DejaVu Sans, sans-serif">""")
    println(buf, """<rect width="100%" height="100%" fill="#ffffff"/>""")
    println(buf, """<text x="$(pad_l + pw/2)" y="32" text-anchor="middle" font-size="15" font-weight="bold" fill="#1f2933">Per-Instance Speedup Quantiles vs Ref #$ref_id ($(_xml_esc(String(ref_run["label"]))))</text>""")

    # Shaded speedup (>1x) and slowdown (<1x) zones
    y_1x = y_map(1.0)
    println(buf, """<rect x="$pad_l" y="$pad_t" width="$pw" height="$(max(0.0, y_1x - pad_t))" fill="#1f9e59" fill-opacity="0.04"/>""")
    println(buf, """<rect x="$pad_l" y="$y_1x" width="$pw" height="$(max(0.0, pad_t + ph - y_1x))" fill="#d1382e" fill-opacity="0.04"/>""")

    for sp_tick in (0.05, 0.1, 0.2, 0.5, 1.0, 2.0, 5.0, 10.0, 20.0)
        (sp_tick < 10.0^l_min || sp_tick > 10.0^l_max) && continue
        yy = y_map(sp_tick)
        println(buf, """<line x1="$pad_l" y1="$yy" x2="$(pad_l + pw)" y2="$yy" stroke="$(sp_tick == 1.0 ? "#323f4b" : "#e4e7eb")" stroke-dasharray="$(sp_tick == 1.0 ? "6,3" : "4,4")" stroke-width="$(sp_tick == 1.0 ? "1.6" : "1")"/>""")
        lbl = sp_tick >= 1.0 ? @sprintf("%.0fx faster", sp_tick) : @sprintf("%.0fx slower", 1.0 / sp_tick)
        sp_tick == 1.0 && (lbl = "1.0x (par)")
        println(buf, """<text x="$(pad_l - 8)" y="$(yy + 4)" text-anchor="end" font-size="10.5" fill="#52606d">$lbl</text>""")
    end

    for pct in 0:20:100
        xx = x_map(pct)
        println(buf, """<line x1="$xx" y1="$pad_t" x2="$xx" y2="$(pad_t + ph)" stroke="#e4e7eb" stroke-dasharray="4,4" stroke-width="1"/>""")
        println(buf, """<text x="$xx" y="$(pad_t + ph + 22)" text-anchor="middle" font-size="11" fill="#52606d">$(pct)%</text>""")
    end

    println(buf, """<line x1="$pad_l" y1="$(pad_t + ph)" x2="$(pad_l + pw)" y2="$(pad_t + ph)" stroke="#323f4b" stroke-width="1.4"/>""")
    println(buf, """<line x1="$pad_l" y1="$pad_t" x2="$pad_l" y2="$(pad_t + ph)" stroke="#323f4b" stroke-width="1.4"/>""")
    println(buf, """<text x="$(pad_l + pw/2)" y="$(H - 16)" text-anchor="middle" font-size="13" fill="#323f4b">Benchmark Instance Percentile (sorted from worst slowdown to largest speedup)</text>""")
    println(buf, """<text x="18" y="$(pad_t + ph/2)" text-anchor="middle" font-size="13" fill="#323f4b" transform="rotate(-90, 18, $(pad_t + ph/2))">Speedup Ratio (t_ref / t_solver)</text>""")

    for c in curves
        isempty(c.speedups) && continue
        n_s = length(c.speedups)
        idxs = unique(round.(Int, range(1, n_s, length=min(n_s, 300))))
        pts = [@sprintf("%.2f,%.2f", x_map(100.0 * (i - 1) / max(1, n_s - 1)), y_map(c.speedups[i])) for i in idxs]
        dash_attr = isempty(c.dash) ? "" : """ stroke-dasharray="$(c.dash)" """
        println(buf, """<polyline fill="none" stroke="$(c.color)" stroke-width="2.6"$dash_attr points="$(join(pts, " "))"/>""")
    end

    leg_w, leg_h = 345.0, 14.0 + 22.0 * length(curves)
    lx, ly = pad_l + 14.0, pad_t + 12.0
    println(buf, """<rect x="$lx" y="$ly" width="$leg_w" height="$leg_h" rx="4" fill="#ffffff" fill-opacity="0.93" stroke="#cbd2d9" stroke-width="1"/>""")
    for (idx, c) in enumerate(curves)
        yy = ly + 8.0 + (idx - 1) * 22.0
        dash_attr = isempty(c.dash) ? "" : """ stroke-dasharray="$(c.dash)" """
        rid = Int(c.run["run_id"])
        lbl = _xml_esc(String(c.run["label"]))
        txt = @sprintf("#%d: %s (Geomean: %.2fx, Faster: %.1f%%)", rid, lbl, c.gm, c.faster_pct)
        println(buf, """<line x1="$(lx + 10)" y1="$(yy + 6)" x2="$(lx + 34)" y2="$(yy + 6)" stroke="$(c.color)" stroke-width="2.6"$dash_attr/>""")
        println(buf, """<text x="$(lx + 42)" y="$(yy + 10)" font-size="10.5" fill="#1f2933">$txt</text>""")
    end

    println(buf, "</svg>")
    out_name = out === nothing ? "speedup_$(ref_id)_vs_$(_run_tag(run_ids)).svg" : out
    return _save_plot(ab_dir, out_name, String(take!(buf)), "Speedup Quantile plot")
end

"""
    plot_phases(run_specs=[:baseline, :last]; out="phases.svg", suite=nothing, dir=pwd())

Generates a 2-Panel Mechanistic Breakdown Chart across multiple solver runs:
- **Left Panel:** Horizontal Stacked Bar Chart of aggregate phase timings per solver (with
  direct checkpoint labels and durations on each bar segment).
- **Right Panel:** Compute Time Breakdown by Instance Difficulty Tier (Fast `<2ms`, Medium
  `2–10ms`, Hard `10–50ms`, Tail `>50ms`, classified by Virtual Best Solver runtime).
"""
function plot_phases(
    run_specs::AbstractVector=[:baseline, :last];
    out::Union{Nothing,AbstractString}=nothing,
    suite::Union{Nothing,AbstractString}=nothing,
    dir::AbstractString=pwd(),
    allow_split_mismatch::Bool=false
)::String
    repo_root = find_repo_root(dir)
    ab_dir = ensure_ablation_dirs(repo_root)
    runs = load_runs(ab_dir)
    isempty(runs) && error("No ablation runs recorded in $(ab_dir)")

    run_ids = Int[]
    for spec in run_specs
        rid = _resolve_run_id(spec, runs, ab_dir; suite=suite)
        rid in run_ids || push!(run_ids, rid)
    end

    run_objs = [runs[findfirst(x -> Int(x["run_id"]) == rid, runs)] for rid in run_ids]
    _check_split_compatibility!(run_objs; allow_split_mismatch=allow_split_mismatch)
    case_maps = [Dict(String(c["name"]) => c for c in load_cases(ab_dir, rid)) for rid in run_ids]
    common = sort!(collect(intersect([keys(cm) for cm in case_maps]...)))

    # Classify common instances by VBS runtime into 4 difficulty tiers
    tiers = [("Fast (<2ms)", 0.0, 0.002), ("Medium (2-10ms)", 0.002, 0.010), ("Hard (10-50ms)", 0.010, 0.050), ("Tail (>50ms)", 0.050, Inf)]
    tier_colors = ["#1f9e59", "#1473d1", "#e68c19", "#d1382e"]
    vbs_t = Dict{String,Float64}()
    for nm in common
        vbs_t[nm] = minimum(max(_extract_case_val(cm[nm], :time_compute), 1e-6) for cm in case_maps)
    end

    W, H = 1260, max(500, 170 + 125 * length(run_ids))
    pad_l1, pad_r1, pad_t, pad_b = 170.0, 35.0, 60.0, 65.0
    pw = (W - pad_l1 - pad_r1 - 75.0) / 2.0
    ph = H - pad_t - pad_b
    x1_0, y1_0 = pad_l1, pad_t
    x2_0, y2_0 = pad_l1 + pw + 75.0, pad_t

    # Gather phase segments per run & build consistent color map across runs
    phase_bars = Vector{Vector{Tuple{String,Float64}}}()
    phase_color_map = Dict{String,String}()
    max_ph_sum = 1e-3
    for cm in case_maps
        ph_tot = Dict{String,Float64}()
        for nm in common
            for (k, v) in get(cm[nm], "phases", Dict{String,Any}())
                ph_tot[String(k)] = get(ph_tot, String(k), 0.0) + Float64(v)
            end
        end
        segs = sort!([(k, v) for (k, v) in ph_tot if v >= 1e-3]; by=x -> -x[2])
        for (k, _) in segs
            if !haskey(phase_color_map, k)
                col, _ = _PALETTE[mod1(length(phase_color_map) + 1, length(_PALETTE))]
                phase_color_map[k] = col
            end
        end
        max_ph_sum = max(max_ph_sum, sum(x[2] for x in segs; init=0.0))
        push!(phase_bars, segs)
    end
    max_ph_sum *= 1.08

    # Gather difficulty tier totals per run
    tier_bars = Vector{Vector{Float64}}()
    max_tier_sum = 1e-3
    for cm in case_maps
        t_sums = zeros(Float64, length(tiers))
        for nm in common
            tv = vbs_t[nm]
            tc = _extract_case_val(cm[nm], :time_compute)
            for (ti, (_, lo, hi)) in enumerate(tiers)
                if lo <= tv < hi
                    t_sums[ti] += tc
                    break
                end
            end
        end
        max_tier_sum = max(max_tier_sum, sum(t_sums))
        push!(tier_bars, t_sums)
    end
    max_tier_sum *= 1.08

    buf = IOBuffer()
    println(buf, """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $W $H" width="$W" height="$H" font-family="Helvetica, Arial, DejaVu Sans, sans-serif">""")
    println(buf, """<rect width="100%" height="100%" fill="#ffffff"/>""")

    println(buf, """<text x="$(x1_0 + pw/2)" y="32" text-anchor="middle" font-size="15" font-weight="bold" fill="#1f2933">Aggregate Checkpoint Breakdown by Solver</text>""")
    println(buf, """<text x="$(x2_0 + pw/2)" y="32" text-anchor="middle" font-size="15" font-weight="bold" fill="#1f2933">Compute Time by Problem Difficulty Tier</text>""")

    # X-axis grids
    for k in 0:5
        v1 = max_ph_sum * k / 5.0
        xx1 = x1_0 + (v1 / max_ph_sum) * pw
        lbl1 = max_ph_sum < 1.0 ? @sprintf("%.0fms", v1 * 1e3) : @sprintf("%.1fs", v1)
        println(buf, """<line x1="$xx1" y1="$y1_0" x2="$xx1" y2="$(y1_0 + ph)" stroke="#e4e7eb" stroke-dasharray="4,4" stroke-width="1"/>""")
        println(buf, """<text x="$xx1" y="$(y1_0 + ph + 22)" text-anchor="middle" font-size="11" fill="#52606d">$lbl1</text>""")

        v2 = max_tier_sum * k / 5.0
        xx2 = x2_0 + (v2 / max_tier_sum) * pw
        lbl2 = max_tier_sum < 1.0 ? @sprintf("%.0fms", v2 * 1e3) : @sprintf("%.1fs", v2)
        println(buf, """<line x1="$xx2" y1="$y2_0" x2="$xx2" y2="$(y2_0 + ph)" stroke="#e4e7eb" stroke-dasharray="4,4" stroke-width="1"/>""")
        println(buf, """<text x="$xx2" y="$(y2_0 + ph + 22)" text-anchor="middle" font-size="11" fill="#52606d">$lbl2</text>""")
    end

    n_r = length(run_ids)
    row_h = ph / n_r
    bar_h = min(34.0, row_h * 0.34)

    for (idx, r) in enumerate(run_objs)
        yc = y1_0 + (idx - 0.68) * row_h
        by = yc - bar_h / 2.0
        rid = Int(r["run_id"])
        lbl = _xml_esc(String(r["label"]))
        println(buf, """<text x="$(x1_0 - 10)" y="$(yc + 4)" text-anchor="end" font-size="12" font-weight="bold" fill="#1f2933">#$rid: $lbl</text>""")

        # Panel 1: Stacked Phase Bar + Complete Per-Row Swatch Legend Below Bar
        cur_x = x1_0
        segs = phase_bars[idx]
        row_ph_tot = max(1e-6, sum(x[2] for x in segs; init=0.0))
        for (pname, pval) in segs
            bw = (pval / max_ph_sum) * pw
            col = get(phase_color_map, pname, "#1473d1")
            println(buf, """<rect x="$cur_x" y="$by" width="$(max(1.5, bw))" height="$bar_h" fill="$col" fill-opacity="0.90" stroke="#ffffff" stroke-width="1"/>""")
            if bw >= 52.0
                v_s = max_ph_sum < 1.0 ? @sprintf("%.0fms", pval * 1e3) : @sprintf("%.1fs", pval)
                println(buf, """<text x="$(cur_x + bw/2)" y="$(yc + 4)" text-anchor="middle" font-size="10" font-weight="bold" fill="#ffffff">$v_s</text>""")
            end
            cur_x += bw
        end

        # Render 3-column swatch legend underneath the bar for every phase in this solver
        for (si, (pname, pval)) in enumerate(segs[1:min(6, length(segs))])
            col_idx = mod1(si, 3) - 1
            row_idx = (si - 1) ÷ 3
            lx = x1_0 + 4.0 + col_idx * (pw / 3.0)
            ly = by + bar_h + 15.0 + row_idx * 16.0
            col = get(phase_color_map, pname, "#1473d1")
            v_s = max_ph_sum < 1.0 ? @sprintf("%.1fms", pval * 1e3) : @sprintf("%.1fs", pval)
            pct_s = @sprintf("%.0f%%", 100.0 * pval / row_ph_tot)
            short_p = length(pname) > 15 ? first(pname, 14) * "…" : pname
            println(buf, """<rect x="$lx" y="$(ly - 8.5)" width="9" height="9" rx="2" fill="$col"/>""")
            println(buf, """<text x="$(lx + 13)" y="$ly" font-size="9.8" fill="#1f2933">$(_xml_esc(short_p)): $v_s ($pct_s)</text>""")
        end

        # Panel 2: Difficulty Tier Stacked Bar + Per-Row Tier Breakdown Below Bar
        cur_x2 = x2_0
        t_vals = tier_bars[idx]
        row_t_tot = max(1e-6, sum(t_vals))
        for (ti, tval) in enumerate(t_vals)
            tval <= 0 && continue
            bw = (tval / max_tier_sum) * pw
            col = tier_colors[ti]
            println(buf, """<rect x="$cur_x2" y="$by" width="$(max(1.5, bw))" height="$bar_h" fill="$col" fill-opacity="0.90" stroke="#ffffff" stroke-width="1"/>""")
            if bw >= 42.0
                v_s = max_tier_sum < 1.0 ? @sprintf("%.0fms", tval * 1e3) : @sprintf("%.1fs", tval)
                println(buf, """<text x="$(cur_x2 + bw/2)" y="$(yc + 4)" text-anchor="middle" font-size="10" font-weight="bold" fill="#ffffff">$v_s</text>""")
            end
            cur_x2 += bw
        end
        for (ti, (tname, _, _)) in enumerate(tiers)
            tval = t_vals[ti]
            col_idx = mod1(ti, 2) - 1
            row_idx = (ti - 1) ÷ 2
            lx = x2_0 + 4.0 + col_idx * (pw / 2.0)
            ly = by + bar_h + 15.0 + row_idx * 16.0
            v_s = max_tier_sum < 1.0 ? @sprintf("%.1fms", tval * 1e3) : @sprintf("%.1fs", tval)
            pct_s = @sprintf("%.0f%%", 100.0 * tval / row_t_tot)
            println(buf, """<rect x="$lx" y="$(ly - 8.5)" width="9" height="9" rx="2" fill="$(tier_colors[ti])"/>""")
            println(buf, """<text x="$(lx + 13)" y="$ly" font-size="9.8" fill="#1f2933">$(_xml_esc(tname)): $v_s ($pct_s)</text>""")
        end
    end

    # Legend for Panel 2 Difficulty Tiers at top of Panel 2
    for (ti, (tname, _, _)) in enumerate(tiers)
        lx = x2_0 + (ti - 1) * (pw / 4.0)
        ly = y2_0 - 16.0
        println(buf, """<rect x="$lx" y="$(ly - 9)" width="11" height="11" rx="2" fill="$(tier_colors[ti])"/>""")
        println(buf, """<text x="$(lx + 15)" y="$ly" font-size="10.5" fill="#323f4b">$(_xml_esc(tname))</text>""")
    end

    println(buf, """<line x1="$x1_0" y1="$(y1_0 + ph)" x2="$(x1_0 + pw)" y2="$(y1_0 + ph)" stroke="#323f4b" stroke-width="1.4"/>""")
    println(buf, """<line x1="$x1_0" y1="$y1_0" x2="$x1_0" y2="$(y1_0 + ph)" stroke="#323f4b" stroke-width="1.4"/>""")
    println(buf, """<line x1="$x2_0" y1="$(y2_0 + ph)" x2="$(x2_0 + pw)" y2="$(y2_0 + ph)" stroke="#323f4b" stroke-width="1.4"/>""")
    println(buf, """<line x1="$x2_0" y1="$y2_0" x2="$x2_0" y2="$(y2_0 + ph)" stroke="#323f4b" stroke-width="1.4"/>""")
    println(buf, """<text x="$(x1_0 + pw/2)" y="$(H - 16)" text-anchor="middle" font-size="13" fill="#323f4b">Aggregate Checkpoint Time</text>""")
    println(buf, """<text x="$(x2_0 + pw/2)" y="$(H - 16)" text-anchor="middle" font-size="13" fill="#323f4b">Total Pure Compute Time by VBS Difficulty Tier</text>""")

    println(buf, "</svg>")
    out_name = out === nothing ? "phases_$(_run_tag(run_ids)).svg" : out
    return _save_plot(ab_dir, out_name, String(take!(buf)), "Phase & Tier Breakdown plot")
end
