function quality_checks(packages, extensions)
    @testset "native package quality" begin
        @test all(extension -> extension !== nothing, extensions)
        ambiguities = Test.detect_ambiguities(packages..., extensions...; recursive=true)
        isempty(ambiguities) || foreach(item -> println(stderr, item), ambiguities)
        @test isempty(ambiguities)
        for package in packages
            @testset "$(nameof(package))" begin
                Aqua.test_unbound_args(package)
                Aqua.test_undefined_exports(package)
                Aqua.test_project_extras(package)
                Aqua.test_deps_compat(package)
                Aqua.test_piracies(package)
            end
        end
    end
end
