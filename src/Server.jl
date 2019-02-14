module RegServer

using Sockets
using GitHub
using HTTP
using Distributed
using Base64
using Pkg

import Pkg: TOML
import ..Registrator: register, RegBranch

include("conf.jl")

function get_sha_from_branch(reponame, brn)
    try
        b = branch(reponame, Branch(brn))
        sha = b.sha != nothing ? b.sha : b.commit.sha
        return sha, nothing
    catch ex
        d = parse_github_exception(ex)
        if d["Status Code"] == "404" && d["Message"] == "Branch not found"
            return nothing, "Branch `$brn` not found"
        else
            rethrow(ex)
        end
    end

    return nothing, nothing
end

function is_comment_by_collaborator(event)
    @debug("Checking if comment is by collaborator")

    k = "pull_request"
    if haskey(event.payload, "comment")
        k = "comment"
    elseif haskey(event.payload, "issue")
        k = "issue"
    end

    user = event.payload[k]["user"]["login"]
    auth = get_jwt_auth()
    tok = create_access_token(Installation(event.payload["installation"]), auth)
    return iscollaborator(event.repository, user; auth=tok)
end

struct CommonParams
    isvalid::Bool
    error::Union{Nothing, String}
    report_error::Bool
end

struct RegParams
    evt::WebhookEvent
    phrase::RegexMatch
    reponame::String
    ispr::Bool
    prid::Union{Nothing, Int}
    branch::Union{Nothing, String}
    comment_by_collaborator::Bool
    cparams::CommonParams

    function RegParams(evt::WebhookEvent, phrase::RegexMatch)
        reponame = evt.repository.full_name
        ispr = true
        prid = nothing
        brn = nothing
        comment_by_collaborator = false
        err = nothing
        report_error = false

        if endswith(reponame, ".jl")
            comment_by_collaborator = is_comment_by_collaborator(evt)
            if comment_by_collaborator
                @debug("Comment is by collaborator")
                if haskey(evt.payload["issue"], "pull_request")
                    @debug("Comment is on a pull request")
                    prid = evt.payload["issue"]["number"]
                else
                    ispr = false
                    brn = "master"
                    arg_regx = r"\((.*?)\)"
                    m = match(arg_regx, phrase.match)
                    if length(m.captures) != 0
                        arg = strip(m.captures[1])
                        if length(arg) != 0
                            @debug("Found branch arguement in comment: $arg")
                            brn = arg
                        end
                    end
                end
            else
                err = "Comment not made by collaborator"
                @debug(err)
            end
        else
            err = "Package name does not end with '.jl'"
            @debug(err)
            report_error = true
        end

        isvalid = comment_by_collaborator
        @debug("Event pre-check validity: $isvalid")

        return new(evt, phrase, reponame, ispr,
                   prid, brn, comment_by_collaborator,
                   CommonParams(isvalid, err, report_error))
    end
end

function is_pfile_valid(c::String)
    if length(c) != 0
        try
            TOML.parse(c)
            ib = IOBuffer(c)
            p = Pkg.Types.read_project(copy(ib))
            if p.name === nothing || p.uuid === nothing || p.version === nothing
                err = "Project file is invalid"
                @debug(err)
                return false, err
            end
            return true, nothing
        catch ex
            if isa(ex, CompositeException) && isa(ex.exceptions[1], TOML.ParserError)
                err = "Error parsing project file"
                @debug(err)
                return false, err
            else
                rethrow(ex)
            end
        end
    else
        err = "Project file is empty"
        @debug(err)
        return false, err
    end
end

struct ProcessedParams
    projectfile_found::Bool
    projectfile_valid::Bool
    sha::Union{Nothing, String}
    cloneurl::Union{Nothing, String}
    cparams::CommonParams

    function ProcessedParams(rp::RegParams)
        if rp.cparams.error != nothing
            @debug("Pre-check failed, not processing RegParams: $(rp.cparams.error)")
            return ProcessedParams(nothing, nothing, copy(rp.cparams))
        end

        projectfile_found = false
        projectfile_valid = false
        sha = nothing
        cloneurl = nothing
        err = nothing
        report_error = true

        if rp.ispr
            pr = pull_request(rp.reponame, rp.prid)
            cloneurl = pr.head.repo.html_url.uri * ".git"
            sha = pr.head.sha
            @debug("Getting PR files repo=$(rp.reponame), prid=$(rp.prid)")
            prfiles = pull_request_files(rp.reponame, rp.prid)

            for f in prfiles
                if f.filename == "Project.toml"
                    @debug("Project file found")
                    projectfile_found = true

                    ref = split(HTTP.URI(f.contents_url).query, "=")[2]

                    @debug("Getting project file details")
                    file_obj = file(rp.reponame, "Project.toml";
                                    params=Dict("ref"=>ref))

                    @debug("Getting project file contents")
                    c = HTTP.get(file_obj.download_url).body |> copy |> String

                    @debug("Checking project file validity")
                    projectfile_valid, err = is_pfile_valid(c)

                    break
                end
            end

            if !projectfile_found
                err = "Project file not found on this Pull request"
                @debug(err)
            end
        else
            cloneurl = rp.evt.payload["repository"]["clone_url"]
            @debug("Getting sha from branch reponame=$(rp.reponame) branch=$(rp.branch)")
            sha, err = get_sha_from_branch(rp.reponame, rp.branch)
            @debug("Got sha=$(repr(sha)) error=$(repr(err))")

            if err == nothing && sha != nothing
                @debug("Getting gitcommit object for sha")
                gcom = gitcommit(rp.reponame, GitCommit(Dict("sha"=>sha)))
                @debug("Getting tree object for sha")
                t = tree(rp.reponame, Tree(gcom.tree))

                for tr in t.tree
                    if tr["path"] == "Project.toml"
                        projectfile_found = true
                        @debug("Project file found")

                        @debug("Getting projectfile blob")
                        b = blob(rp.reponame, Blob(tr["sha"]);
                                 auth=GitHub.authenticate(GITHUB_TOKEN))

                        @debug("Decoding base64 projectfile contents")
                        c = join([String(copy(base64decode(k))) for k in split(b.content)])

                        @debug("Checking project file validity")
                        projectfile_valid, err = is_pfile_valid(c)
                        break
                    end
                end

                if !projectfile_found
                    err = "Project file not found on branch `$(rp.branch)`"
                    @debug(err)
                end
            end
        end

        isvalid = rp.comment_by_collaborator && projectfile_found && projectfile_valid
        @debug("Event validity: $(isvalid)")

        new(projectfile_found, projectfile_valid, sha, cloneurl,
            CommonParams(isvalid, err, report_error))
    end
end

function get_backtrace(ex)
    v = IOBuffer()
    Base.showerror(v, ex, catch_backtrace())
    return v.data |> copy |> String
end

function get_jwt_auth()
    GitHub.JWTAuth(GITHUB_APP_ID, GITHUB_PRIV_PEM)
end

function start_github_webhook(http_ip=DEFAULT_HTTP_IP, http_port=DEFAULT_HTTP_PORT)
    auth = get_jwt_auth()
    listener = GitHub.CommentListener(comment_handler, TRIGGER; check_collab=false, auth=auth, secret=GITHUB_SECRET)
    GitHub.run(listener, IPv4(http_ip), http_port)
end

const event_queue = Vector{RegParams}()

function make_comment(evt::WebhookEvent, body::String)
    @debug("Posting comment to PR/issue")
    headers = Dict("private_token" => GITHUB_TOKEN)
    params = Dict("body" => body)
    repo = evt.repository
    GitHub.create_comment(repo, evt.payload["issue"]["number"],
                          :issue; headers=headers,
                          params=params, auth=GitHub.authenticate(GITHUB_TOKEN))
end

function raise_issue(event, phrase, bt)
    repo = event.repository.full_name
    num = event.payload["issue"]["number"]
    title = "Error registering $repo#$num"
    input_phrase = "`[" * phrase.match[2:end-1] * "]`"
    body = """
Repository: $repo
Issue/PR: [$num]($(event.payload["issue"]["html_url"]))
Command: $(input_phrase)
Stacktrace:

```
$bt
```
"""
    params = Dict("title"=>title, "body"=>body)
    iss = create_issue(REGISTRATOR_REPO; params=params, auth=GitHub.authenticate(GITHUB_TOKEN))
    make_comment(event, "Unexpected error occured during registration, see issue: [$(REGISTRATOR_REPO)#$(iss.number)]($(iss.html_url))")
end

function comment_handler(event::WebhookEvent, phrase::RegexMatch)
    global event_queue

    @debug("Received event for $(event.repository.full_name), phrase: $phrase")
    try
        handle_comment_event(event, phrase)
    catch ex
        bt = get_backtrace(ex)
        @info("Unexpected error: $bt")
        REPORT_ISSUE && raise_issue(event, phrase, bt)
    end

    return HTTP.Messages.Response(200)
end

function handle_comment_event(event::WebhookEvent, phrase::RegexMatch)
    rp = RegParams(event, phrase)

    if rp.cparams.isvalid && rp.cparams.error == nothing
        if rp.ispr
            @info("Creating registration pull request for $(rp.reponame) PR: $(rp.prid)")
        else
            @info("Creating registration pull request for $(rp.reponame) branch: `$(rp.branch)`")
        end

        push!(event_queue, rp)

        if !DEV_MODE
            params = Dict("state" => "pending",
                          "context" => GITHUB_USER,
                          "description" => "pending")
            GitHub.create_status(repo, commit;
                                 auth=get_jwt_auth(),
                                 params=params)
        end
    elseif rp.cparams.error != nothing
        @info("Error while processing event: $(rp.cparams.error)")
        if rp.cparams.report_error
            make_comment(event, "Error while trying to register: $(rp.cparams.error)")
        end
    end
end

function recover(f)
    while true
        try
            f()
        catch ex
            @info("Task $f failed")
            @info(get_backtrace(ex))
        end

        sleep(CYCLE_INTERVAL)
    end
end

macro recover(e)
    :(recover(() -> $(esc(e)) ))
end

function parse_github_exception(ex::ErrorException)
    msgs = map(strip, split(ex.msg, '\n'))
    d = Dict()
    for m in msgs
        a, b = split(m, ":"; limit=2)
        d[a] = strip(b)
    end
    return d
end

function is_pr_exists_exception(ex)
    d = parse_github_exception(ex)

    if d["Status Code"] == "422" &&
       match(r"A pull request already exists", d["Errors"]) != nothing
        return true
    end

    return false
end

function make_pull_request(pp::ProcessedParams, rp::RegParams, rbrn::RegBranch)
    name = rbrn.name
    ver = rbrn.version
    brn = rbrn.branch

    @info("Creating pull request name=$name, ver=$ver, branch=$brn")
    payload = rp.evt.payload
    creator = payload["issue"]["user"]["login"]
    reviewer = payload["sender"]["login"]
    @debug("Pull request creator=$creator, reviewer=$reviewer")

    params = Dict("title"=>"Register $name: $ver",
                  "base"=>REGISTRY_BASE_BRANCH,
                  "head"=>brn,
                  "maintainer_can_modify"=>true)

    params["body"] = """Register $name: $ver
cc: @$(creator)
reviewer: @$(reviewer)"""

    pr = nothing
    repo = join(split(REGISTRY, "/")[end-1:end], "/")
    try
        pr = create_pull_request(repo; auth=GitHub.authenticate(GITHUB_TOKEN), params=params)
        @debug("Pull request created")
    catch ex
        if is_pr_exists_exception(ex)
            @debug("Pull request already exists, not creating")
        else
            rethrow(ex)
        end
    end

    msg = "created"

    if pr == nothing
        @debug("Searching for existing PR")
        for p in pull_requests(repo; auth=GitHub.authenticate(GITHUB_TOKEN))[1]
            if p.base.ref == REGISTRY_BASE_BRANCH && p.head.ref == brn
                @debug("PR found")
                pr = p
                break
            end
        end
        msg = "updated"
    end

    if pr == nothing
        error("Existing PR not found")
    end

    cbody = "Registration pull request $msg: [$(repo)/$(pr.number)]($(pr.html_url))"
    make_comment(rp.evt, cbody)
end

function handle_register_events(rp::RegParams)
    @info("Processing Register event for $(rp.reponame)")
    try
        handle_register(rp)
    catch ex
        bt = get_backtrace(ex)
        @info("Unexpected error: $bt")
        REPORT_ISSUE && raise_issue(rp.evt, rp.phrase, bt)
    end
    @info("Done processing event for $(rp.reponame)")
end

function handle_register(rp::RegParams)
    pp = ProcessedParams(rp)

    if pp.cparams.isvalid && pp.cparams.error == nothing
        rbrn = register(pp.cloneurl, pp.sha; registry=REGISTRY, push=true)
        make_pull_request(pp, rp, rbrn)
    elseif pp.cparams.error != nothing
        @info("Error while processing event: $(pp.cparams.error)")
        if pp.cparams.report_error
            make_comment(rp.evt, "Error while trying to register: $(pp.cparams.error)")
        end
    end
end

function tester()
    global event_queue

    while true
        while !isempty(event_queue)
            rp = popfirst!(event_queue)
            handle_register_events(rp)
        end

        sleep(CYCLE_INTERVAL)
    end
end

function main()
    @async @recover tester()
    @recover start_github_webhook()
end

end    # module
