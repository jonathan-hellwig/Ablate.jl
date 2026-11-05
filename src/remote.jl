# ==============================================================================
# src/remote.jl — Server Workflow, Interrupted-Run Recovery & Remote Sync
# ==============================================================================

"""
    import_ablation!(src_path::AbstractString; dir::AbstractString=pwd())::Vector{Int}

Merges an external `.ablation` directory (or repository containing `.ablation`) into
the local `.ablation` ledger without run ID collisions:
1. Copies any missing `.diff` code snapshots into `.ablation/patches/`.
2. Skips runs already present locally (matched by `timestamp`, `code_signature`, `label`, `suite`).
3. Assigns new sequential local `run_id`s to newly imported runs and copies their `cases/run_<id>.jsonl`.
Returns the list of newly assigned local `run_id`s.
"""
function import_ablation!(src_path::AbstractString; dir::AbstractString=pwd())::Vector{Int}
    src_ab = isdir(joinpath(src_path, ".ablation")) ? joinpath(src_path, ".ablation") : src_path
    isdir(src_ab) || error("Source ablation directory not found: $src_ab")

    repo_root = find_repo_root(dir)
    dst_ab = ensure_ablation_dirs(repo_root)

    # 1. Copy missing patches
    src_patches = joinpath(src_ab, "patches")
    if isdir(src_patches)
        for f in readdir(src_patches)
            endswith(f, ".diff") || continue
            sp = joinpath(src_patches, f)
            dp = joinpath(dst_ab, "patches", f)
            isfile(dp) || cp(sp, dp)
        end
    end

    # 2. Load local & remote runs
    local_runs = load_runs(dst_ab)
    remote_runs = load_runs(src_ab)
    existing_keys = Set(
        (String(r["timestamp"]), String(r["code_signature"]), String(r["label"]), String(r["suite"]))
        for r in local_runs
    )

    next_id = isempty(local_runs) ? 1 : maximum(Int(r["run_id"]) for r in local_runs) + 1
    imported_ids = Int[]

    runs_file = joinpath(dst_ab, "runs.jsonl")
    for r in remote_runs
        key = (String(r["timestamp"]), String(r["code_signature"]), String(r["label"]), String(r["suite"]))
        key in existing_keys && continue

        old_id = Int(r["run_id"])
        new_id = next_id
        next_id += 1

        r_new = copy(r)
        r_new["run_id"] = new_id
        r_new["imported_from_id"] = old_id

        src_cases = joinpath(src_ab, "cases", "run_$(old_id).jsonl")
        dst_cases = joinpath(dst_ab, "cases", "run_$(new_id).jsonl")
        if isfile(src_cases)
            cp(src_cases, dst_cases; force=true)
        end

        open(runs_file, "a") do io
            to_json(io, r_new)
            write(io, '\n')
        end
        push!(existing_keys, key)
        push!(imported_ids, new_id)
    end

    printstyled("⬇ Imported $(length(imported_ids)) new run(s) into $(dst_ab): $(imported_ids)\n"; bold=true, color=:green)
    return imported_ids
end

"""
    pull_remote!(remote_spec::AbstractString; dir::AbstractString=pwd())::Vector{Int}

Pulls `.ablation/` from a remote server via `rsync` over SSH (e.g. `remote_spec = "user@server:~/Work/nra"`)
and merges all new runs and patches into the local `.ablation/` ledger.
"""
function pull_remote!(remote_spec::AbstractString; dir::AbstractString=pwd())::Vector{Int}
    src = endswith(remote_spec, ".ablation") || endswith(remote_spec, ".ablation/") ?
          rstrip(remote_spec, '/') * "/" :
          rstrip(remote_spec, '/') * "/.ablation/"

    return mktempdir() do tmp
        printstyled("⟳ Syncing remote ablation data from $src ...\n"; color=:cyan)
        run(`rsync -az $src $tmp/`)
        import_ablation!(tmp; dir=dir)
    end
end
