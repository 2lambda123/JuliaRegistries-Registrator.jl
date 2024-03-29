@testset "Trigger comment" begin
    trigger = make_trigger(Dict("trigger" => "@JuliaRegistrator"))
    @test match(trigger, "@JuliaRegistrator hi") !== nothing
    @test match(trigger, "@juliaregistrator hi") !== nothing
    @test match(trigger, "@Zuliaregistrator hi") === nothing
    @test match(trigger, "@zuliaregistrator hi") === nothing
end

@testset "parse_comment" begin
    @test parse_comment("register()") == ("register", Dict{Symbol,String}())
    @test parse_comment("approved()") == ("approved", Dict{Symbol,String}())

    @test parse_comment("register(target=qux)") == ("register", Dict(:target=>"qux"))
    @test parse_comment("register(target=qux, branch=baz)") == ("register", Dict(:branch=>"baz",:target=>"qux"))
    @test parse_comment("register(target=foo, branch=bar)") == ("register", Dict(:branch=>"bar",:target=>"foo"))

    @test parse_comment("register(branch=\"release-1.0\")") == ("register", Dict(:branch=>"release-1.0"))

    @test parse_comment("register") == ("register", Dict{Symbol, String}())
    @test parse_comment("register branch=foo target=bar") == ("register", Dict(:branch => "foo", :target => "bar"))
    @test parse_comment("register branch = foo target = bar") == ("register", Dict(:branch => "foo", :target => "bar"))
    @test parse_comment("register branch=foo, target=bar") == ("register", Dict(:branch => "foo", :target => "bar"))

    @test parse_comment("register(branch=foo)\nfoobar\"") == ("register", Dict(:branch => "foo"))

    @test parse_comment("register branch=foo branch=bar") == (nothing, nothing)
end
