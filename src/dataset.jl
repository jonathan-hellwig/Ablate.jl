# ==============================================================================
# dataset.jl — Versioned Benchmark Manifests, Checksums & Leak-Free Splits
# ==============================================================================

struct DatasetSplit
    name::String
    version::String
    split::String
    family::String
    root_dir::String
    files::Vector{String}
    relpaths::Vector{String}
    suite::String
    suite_hash::String
    split_sha256::String
end

function _sha256_file(path::AbstractString)::String
    return bytes2hex(open(sha256, path))
end

"""
    create_manifest(bench_dir; name=basename(normpath(bench_dir)), version="1.0.0", train_fraction=0.15, seed=42, ext=".smt2") -> String

Generates `data.toml`, `train.txt`, and `test.txt` inside `bench_dir`, stratified by
top-level subdirectory (family), with SHA-256 checksums for every file and split.
"""
function create_manifest(
    bench_dir::AbstractString;
    name::AbstractString=basename(normpath(bench_dir)),
    version::AbstractString="1.0.0",
    train_fraction::Real=0.15,
    seed::Integer=42,
    ext::AbstractString=".smt2",
)::String
    isdir(bench_dir) || error("Benchmark directory not found: $bench_dir")
    by_family = Dict{String,Vector{String}}()
    for (root, _, fnames) in walkdir(bench_dir)
        for f in fnames
            endswith(f, ext) || continue
            full = joinpath(root, f)
            rel = replace(relpath(full, bench_dir), '\\' => '/')
            fam = first(split(rel, '/'; limit=2))
            push!(get!(by_family, String(fam), String[]), rel)
        end
    end
    isempty(by_family) && error("No '$ext' files found in $bench_dir")

    rng = MersenneTwister(seed)
    train_files = String[]
    test_files = String[]
    for fam in sort!(collect(keys(by_family)))
        items = sort!(by_family[fam])
        shuffle!(rng, items)
        n = length(items)
        n_train = n == 1 ? 0 : clamp(round(Int, train_fraction * n), 1, n - 1)
        append!(train_files, items[1:n_train])
        append!(test_files, items[(n_train + 1):end])
    end
    sort!(train_files)
    sort!(test_files)

    function _write_split(filename::AbstractString, rels::Vector{String})
        out_path = joinpath(bench_dir, filename)
        open(out_path, "w") do io
            for rel in rels
                println(io, _sha256_file(joinpath(bench_dir, rel)), "  ", rel)
            end
        end
        return _sha256_file(out_path)
    end

    train_sha = _write_split("train.txt", train_files)
    test_sha = _write_split("test.txt", test_files)

    manifest_path = joinpath(bench_dir, "data.toml")
    manifest_data = Dict{String,Any}(
        "name" => String(name),
        "version" => String(version),
        "created_at" => Dates.format(today(), dateformat"yyyy-mm-dd"),
        "split_seed" => Int(seed),
        "split_strategy" => "stratified_by_family",
        "train_fraction" => Float64(train_fraction),
        "splits" => Dict{String,Any}(
            "train" => Dict{String,Any}("file" => "train.txt", "count" => length(train_files), "sha256" => train_sha),
            "test" => Dict{String,Any}("file" => "test.txt", "count" => length(test_files), "sha256" => test_sha),
        ),
    )
    open(manifest_path, "w") do io
        TOML.print(io, manifest_data)
    end
    return manifest_path
end

"""
    load_dataset(manifest_path; split="test", family="", limit=nothing, verify=true) -> DatasetSplit

Loads a versioned split from `data.toml`, verifies the split file's SHA-256 and
(when `verify=true`) every selected benchmark file's SHA-256 checksum.
"""
function load_dataset(
    manifest_path::AbstractString;
    split::AbstractString="test",
    family::AbstractString="",
    limit::Union{Int,Nothing}=nothing,
    verify::Bool=true,
)::DatasetSplit
    isfile(manifest_path) || error("Manifest not found: $manifest_path")
    meta = TOML.parsefile(manifest_path)
    splits = get(meta, "splits", Dict{String,Any}())
    haskey(splits, split) || error("Split '$split' not found in $manifest_path (available: $(join(sort!(collect(keys(splits))), ", ")))")
    split_info = splits[split]

    root_dir = dirname(abspath(manifest_path))
    split_file = joinpath(root_dir, String(split_info["file"]))
    isfile(split_file) || error("Split file not found: $split_file")

    expected_split_sha = String(split_info["sha256"])
    actual_split_sha = _sha256_file(split_file)
    actual_split_sha == expected_split_sha || error("Checksum mismatch for $split_file: expected $expected_split_sha, got $actual_split_sha")

    files = String[]
    relpaths = String[]
    selected_lines = String[]
    fam_prefix = isempty(family) ? "" : (endswith(family, "/") ? String(family) : String(family) * "/")

    for raw_line in eachline(split_file)
        line = strip(raw_line)
        isempty(line) && continue
        parts = Base.split(line, "  "; limit=2)
        length(parts) == 2 || error("Malformed checksum line in $split_file: $line")
        expected_hash, rel_path = String(parts[1]), String(parts[2])
        !isempty(fam_prefix) && !startswith(rel_path, fam_prefix) && continue

        full_path = joinpath(root_dir, rel_path)
        isfile(full_path) || error("Benchmark file missing: $full_path")
        if verify
            actual_hash = _sha256_file(full_path)
            actual_hash == expected_hash || error("Checksum mismatch for $rel_path: expected $expected_hash, got $actual_hash")
        end
        push!(files, full_path)
        push!(relpaths, rel_path)
        push!(selected_lines, line)
        limit !== nothing && length(files) >= limit && break
    end

    name = String(meta["name"])
    version = String(meta["version"])
    suite = isempty(family) ? "$(name)@$(version):$(split)" : "$(name)@$(version):$(split):$(family)"
    suite_hash = isempty(family) ? expected_split_sha[1:min(10, end)] : bytes2hex(sha256(join(selected_lines, "\n")))[1:10]

    return DatasetSplit(
        name,
        version,
        String(split),
        String(family),
        root_dir,
        files,
        relpaths,
        suite,
        suite_hash,
        expected_split_sha,
    )
end

"""
    assert_train_split(split_or_ds; allow_test_leakage=false)

Guardrail for hyperparameter tuning/sweeps: errors if `split == "test"` unless
`allow_test_leakage=true` is explicitly passed.
"""
function assert_train_split(ds::DatasetSplit; allow_test_leakage::Bool=false)
    return assert_train_split(ds.split; allow_test_leakage=allow_test_leakage)
end

function assert_train_split(split_name::AbstractString; allow_test_leakage::Bool=false)
    if split_name == "test" && !allow_test_leakage
        error("Refusing to tune/sweep on the held-out 'test' split (pass allow_test_leakage=true to override).")
    end
    return true
end

function _run_split(r::AbstractDict)::String
    p = get(r, "params", Dict{String,Any}())
    s = get(r, "split", get(p, "split", ""))
    return s === nothing ? "" : String(s)
end

function _check_split_compatibility!(runs::AbstractVector; allow_split_mismatch::Bool=false)
    allow_split_mismatch && return true
    splits = unique!(filter!(!isempty, [_run_split(r) for r in runs]))
    if length(splits) > 1
        error("Refusing to compare/plot runs across different dataset splits ($(join(splits, " vs "))). Pass allow_split_mismatch=true to override.")
    end
    return true
end
