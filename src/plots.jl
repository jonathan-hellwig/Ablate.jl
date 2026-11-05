# ==============================================================================
# src/plots.jl — Zero-Dependency Publication SVG (+ PNG) Plotting for Ablate.jl
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

function _maybe_export_png(svg_path::AbstractString; png::Bool=true)::Union{Nothing,String}
    png || return nothing
    png_path = replace(svg_path, r"\.svg$"i => "") * ".png"
    ok, _ = _read_cmd_safe(`which rsvg-convert`)
    if ok
        _read_cmd_safe(`rsvg-convert -z 2 -b white -o $png_path $svg_path`)
        isfile(png_path) && return png_path
    end
    ok_m, _ = _read_cmd_safe(`which magick`)
    if ok_m
        _read_cmd_safe(`magick -density 192 $svg_path $png_path`)
        isfile(png_path) && return png_path
    end
    return nothing
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
    else
        return "10^$(e) s"
    end
end

"""
    plot_cactus(run_specs=[:baseline, :last]; out="cactus.svg", suite=nothing, dir=pwd(), metric=:time_compute, png=true)

Generates a publication-ready 2-panel SVG (and PNG if `rsvg-convert` is available):
- **Left Panel:** Cactus plot (Solved Count vs. Log-Scale Runtime per Instance).
- **Right Panel:** Cumulative Time vs. Solved Count with shaded area bands.
Returns the path to the generated SVG file.
"""
function plot_cactus(
    run_specs::AbstractVector=[:baseline, :last];
    out::AbstractString="cactus.svg",
    suite::Union{Nothing,AbstractString}=nothing,
    dir::AbstractString=pwd(),
    metric::Symbol=:time_compute,
    png::Bool=true
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

    series = NamedTuple{(:run, :times, :color, :dash),Tuple{Dict{String,Any},Vector{Float64},String,String}}[]
    for (idx, rid) in enumerate(run_ids)
        r = runs[findfirst(x -> Int(x["run_id"]) == rid, runs)]
        cases = load_cases(ab_dir, rid)
        ok_cases = filter(c -> Bool(get(c, "ok", get(c, "solved", true))), cases)
        ts = sort!([max(_extract_case_val(c, metric), 1e-6) for c in ok_cases])
        col, dash = _PALETTE[mod1(idx, length(_PALETTE))]
        push!(series, (run=r, times=ts, color=col, dash=dash))
    end

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

    # Legends
    leg_h = 14 + 22 * length(series)
    println(buf, """<rect x="$(x1_0 + 12)" y="$(y1_0 + 10)" width="255" height="$leg_h" rx="4" fill="#ffffff" fill-opacity="0.92" stroke="#cbd2d9" stroke-width="1"/>""")
    println(buf, """<rect x="$(x2_0 + 12)" y="$(y2_0 + 10)" width="255" height="$leg_h" rx="4" fill="#ffffff" fill-opacity="0.92" stroke="#cbd2d9" stroke-width="1"/>""")

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

    println(buf, "</svg>")
    svg_path = _default_plot_path(ab_dir, out)
    write(svg_path, String(take!(buf)))
    png_path = _maybe_export_png(svg_path; png=png)

    printstyled("📊 Saved Cactus plot:\n"; bold=true, color=:green)
    println("  - SVG: $svg_path")
    png_path !== nothing && println("  - PNG: $png_path")
    return svg_path
end

"""
    plot_scatter(run_a=:baseline, run_b=:last; out="scatter.svg", suite=nothing, dir=pwd(), metric=:time_compute, png=true)

Generates a Log-Log Head-to-Head Scatter Plot comparing per-case runtime in `run_a` (x-axis)
vs `run_b` (y-axis), with 1x, 2x, and 10x guide bands and automatic outlier labels.
"""
function plot_scatter(
    run_a=:baseline,
    run_b=:last;
    out::AbstractString="scatter.svg",
    suite::Union{Nothing,AbstractString}=nothing,
    dir::AbstractString=pwd(),
    metric::Symbol=:time_compute,
    png::Bool=true
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
        if (ratio > 1.5 || ratio < 0.67) && abs(tb - ta) >= 1e-3
            short_n = _xml_esc(basename(name))
            println(buf, """<text x="$(xx + 6)" y="$(yy - 4)" font-size="9.5" fill="$col">$short_n</text>""")
        end
    end

    println(buf, "</svg>")
    svg_path = _default_plot_path(ab_dir, out)
    write(svg_path, String(take!(buf)))
    png_path = _maybe_export_png(svg_path; png=png)

    printstyled("📊 Saved Scatter plot:\n"; bold=true, color=:green)
    println("  - SVG: $svg_path")
    png_path !== nothing && println("  - PNG: $png_path")
    return svg_path
end
