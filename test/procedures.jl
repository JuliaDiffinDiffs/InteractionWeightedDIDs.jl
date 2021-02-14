@testset "CheckVcov" begin
    hrs = exampledata("hrs")
    nt = (data=hrs, esample=trues(size(hrs,1)), vcov=Vcov.robust())
    @test checkvcov!(nt...) == (NamedTuple(), false)
    nt = merge(nt, (vcov=Vcov.cluster(:hhidpn),))
    @test checkvcov!(nt...) == ((esample=trues(size(hrs,1)),), false)

    @test CheckVcov()((data=hrs, esample=trues(size(hrs,1)))) ==
        (data=hrs, esample=trues(size(hrs,1)))
end

@testset "CheckFEs" begin
    hrs = exampledata("hrs")
    nt = (data=hrs, esample=trues(size(hrs,1)), xterms=(term(:white),), drop_singletons=true)
    @test checkfes!(nt...) == ((xterms=(term(:white),), esample=trues(size(hrs,1)),
        fes=FixedEffect[], fenames=Symbol[], has_fe_intercept=false, nsingle=0), false)
    nt = merge(nt, (xterms=(fe(:hhidpn),),))
    @test checkfes!(nt...) == ((xterms=(InterceptTerm{false}(),), esample=trues(size(hrs,1)),
        fes=[FixedEffect(hrs.hhidpn)], fenames=[:fe_hhidpn], has_fe_intercept=true, nsingle=0), false)
    
    df = DataFrame(hrs)
    df = df[(df.wave.==7).|((df.wave.==8).&(df.wave_hosp.==8)), :]
    nobs = size(df, 1)
    nt = merge(nt, (data=df, esample=trues(nobs)))
    kept = df.wave_hosp.==8
    @test checkfes!(nt...) == ((xterms=(InterceptTerm{false}(),), esample=kept,
        fes=[FixedEffect(df.hhidpn)], fenames=[:fe_hhidpn], has_fe_intercept=true,
        nsingle=nobs-sum(kept)), false)

    df = df[df.wave.==7, :]
    nobs = size(df, 1)
    nt = merge(nt, (data=df, esample=trues(nobs)))
    @test_throws ErrorException checkfes!(nt...)

    @test_throws ErrorException CheckFEs()(nt)
    nt = merge(nt, (drop_singletons=false, esample=trues(nobs)))
    @test CheckFEs()(nt) == merge(nt, (xterms=(InterceptTerm{false}(),),
        fes=[FixedEffect(df.hhidpn)], fenames=[:fe_hhidpn], has_fe_intercept=true, nsingle=0))
end

@testset "MakeFESolver" begin
    hrs = exampledata("hrs")
    nobs = size(hrs, 1)
    fes = FixedEffect[FixedEffect(hrs.hhidpn)]
    fenames = [:fe_hhidpn]
    nt = (fenames=fenames, weights=uweights(nobs), esample=trues(nobs), fes=fes)
    ret, share = makefesolver(nt...)
    @test ret.feM isa FixedEffects.FixedEffectSolverCPU{Float64}
    nt = merge(nt, (fenames=Symbol[], fes=FixedEffect[]))
    @test makefesolver(nt...) == ((feM=nothing,), true)
    @test MakeFESolver()(nt) == merge(nt, (feM=nothing,))
end

@testset "MakeYXCols" begin
    hrs = exampledata("hrs")
    nobs = size(hrs, 1)
    nt = (data=hrs, weights=uweights(nobs), esample=trues(nobs), feM=nothing, has_fe_intercept=false, default(MakeYXCols())...)
    ret, share = makeyxcols(nt..., (term(:oop_spend),), (term(1),))
    @test ret.yxcols == Dict(term(:oop_spend)=>hrs.oop_spend, term(1)=>ones(nobs, 1))

    wt = Weights(hrs.rwthh)
    nt = merge(nt, (weights=wt,))
    ret, share = makeyxcols(nt..., (term(:oop_spend), term(:riearnsemp)), (term(:male),))
    @test ret.yxcols == Dict(term(:oop_spend)=>hrs.oop_spend.*sqrt.(wt),
        term(:riearnsemp)=>hrs.riearnsemp.*sqrt.(wt),
        term(:male)=>reshape(hrs.male.*sqrt.(wt), nobs, 1))

    df = DataFrame(hrs)
    df.riearnsemp[1] = NaN
    nt = merge(nt, (data=df,))
    @test_throws ErrorException makeyxcols(nt..., (term(:riearnsemp),), (term(1),))
    df.spouse = convert(Vector{Float64}, df.spouse)
    df.spouse[1] = Inf
    @test_throws ErrorException makeyxcols(nt..., (term(:oop_spend),), (term(:spouse),))

    df = DataFrame(hrs)
    x = randn(nobs)
    df.x = x
    wt = uweights(nobs)
    fes = [FixedEffect(df.hhidpn)]
    feM = AbstractFixedEffectSolver{Float64}(fes, wt, Val{:cpu}, Threads.nthreads())
    nt = merge(nt, (data=df, weights=wt, feM=feM, has_fe_intercept=true))
    ret, share = makeyxcols(nt..., (term(:oop_spend),), (InterceptTerm{false}(), term(:x)))
    resids = reshape(copy(df.oop_spend), nobs, 1)
    _feresiduals!(resids, feM, 1e-8, 10000)
    resids .*= sqrt.(wt)
    @test ret.yxcols[term(:oop_spend)] == reshape(resids, nobs)
    # Verify input data are not modified
    @test df.oop_spend == hrs.oop_spend
    @test df.x == x

    df = DataFrame(hrs)
    esample = df.rwthh.> 0
    nobs = sum(esample)
    wt = Weights(hrs.rwthh[esample])
    fes = [FixedEffect(df.hhidpn[esample])]
    feM = AbstractFixedEffectSolver{Float64}(fes, wt, Val{:cpu}, Threads.nthreads())
    nt = merge(nt, (data=df, esample=esample, weights=wt, feM=feM, has_fe_intercept=true))
    ret, share = makeyxcols(nt..., (term(:oop_spend),), (InterceptTerm{false}(),))
    resids = reshape(df.oop_spend[esample], nobs, 1)
    _feresiduals!(resids, feM, 1e-8, 10000)
    resids .*= sqrt.(wt)
    @test ret.yxcols == Dict(term(:oop_spend)=>reshape(resids, nobs))
    # Verify input data are not modified
    @test df.oop_spend == hrs.oop_spend

    allntargs = NamedTuple[(yterm=term(:oop_spend), xterms=())]
    @test combinedargs(MakeYXCols(), allntargs) == ((term(:oop_spend),), ())
    push!(allntargs, allntargs[1])
    @test combinedargs(MakeYXCols(), allntargs) == ((term(:oop_spend),), ())
    push!(allntargs, (yterm=term(:riearnsemp), xterms=(InterceptTerm{false}(),)))
    @test combinedargs(MakeYXCols(), allntargs) ==
        ((term(:oop_spend),term(:riearnsemp)), (InterceptTerm{false}(),))
    push!(allntargs, (yterm=term(:riearnsemp), xterms=(term(:male),)))
    @test combinedargs(MakeYXCols(), allntargs) ==
        ((term(:oop_spend),term(:riearnsemp)),
        (InterceptTerm{false}(), term(:male)))
    
    nt = merge(nt, (data=df, yterm=term(:oop_spend), xterms=(InterceptTerm{false}(),)))
    @test MakeYXCols()(nt) ==
        merge(nt, (yxcols=Dict(term(:oop_spend)=>reshape(resids, nobs)),))
end

@testset "MakeTreatCols" begin
    hrs = exampledata("hrs")
    nobs = size(hrs, 1)
    tr = dynamic(:wave, -1)
    nt = (data=hrs, treatname=:wave_hosp, treatintterms=(), feM=nothing,
        weightname=nothing, weights=uweights(nobs), esample=trues(nobs),
        tr_rows=hrs.wave_hosp.!=11, default(MakeTreatCols())...)
    ret, share = maketreatcols(nt..., typeof(tr), tr.time, Set([-1]))
    @test length(ret.itreats) == 12
    @test ret.itreats[(rel=0, wave_hosp=10)] ==
        collect(1:nobs)[(hrs.wave_hosp.==10).&(hrs.wave.==10)]
    col = convert(Vector{Float64}, (hrs.wave_hosp.==10).&(hrs.wave.==10))
    @test ret.treatcols[(rel=0, wave_hosp=10)] == col
    @test ret.cellweights == ret.cellcounts
    w = ret.cellweights
    @test all(x->x==252, getindices(w, filter(x->x.wave_hosp==8, keys(w))))
    @test all(x->x==176, getindices(w, filter(x->x.wave_hosp==9, keys(w))))
    @test all(x->x==163, getindices(w, filter(x->x.wave_hosp==10, keys(w))))

    nt = merge(nt, (treatintterms=(term(:male),),))
    ret, share = maketreatcols(nt..., typeof(tr), tr.time, Set([-1]))
    @test length(ret.itreats) == 24
    @test ret.itreats[(rel=0, wave_hosp=10, male=1)] ==
        collect(1:nobs)[(hrs.wave_hosp.==10).&(hrs.wave.==10).&(hrs.male.==1)]

    nt = merge(nt, (cohortinteracted=false, treatintterms=()))
    ret, share = maketreatcols(nt..., typeof(tr), tr.time, Set([-1]))
    @test length(ret.itreats) == 6
    @test ret.itreats[(rel=0,)] ==
        collect(1:nobs)[(hrs.wave_hosp.==hrs.wave).&(hrs.wave_hosp.!=11)]
    col1 = convert(Vector{Float64}, (hrs.wave_hosp.==hrs.wave).&(hrs.wave_hosp.!=11))
    @test ret.treatcols[(rel=0,)] == col1

    nt = merge(nt, (treatintterms=(term(:male),),))
    ret, share = maketreatcols(nt..., typeof(tr), tr.time, Set([-1]))
    @test length(ret.itreats) == 12
    @test ret.itreats[(rel=0, male=1)] ==
        collect(1:nobs)[(hrs.wave_hosp.==hrs.wave).&(hrs.wave_hosp.!=11).&(hrs.male.==1)]

    df = DataFrame(hrs)
    esample = df.rwthh.> 0
    nobs = sum(esample)
    wt = Weights(hrs.rwthh[esample])
    fes = [FixedEffect(df.hhidpn[esample])]
    feM = AbstractFixedEffectSolver{Float64}(fes, wt, Val{:cpu}, Threads.nthreads())
    nt = merge(nt, (data=df, feM=feM, weightname=:rwthh, weights=wt, esample=esample,
        treatintterms=(), cohortinteracted=true))
    ret, share = maketreatcols(nt..., typeof(tr), tr.time, Set([-1]))
    col = reshape(col[esample], nobs, 1)
    defaults = (default(MakeTreatCols())...,)
    _feresiduals!(col, feM, defaults[[2,3]]...)
    @test ret.treatcols[(rel=0, wave_hosp=10)] == (col.*sqrt.(wt))[:]
    @test ret.cellcounts == w
    @test ret.cellweights[(rel=0, wave_hosp=10)] == 881700

    allntargs = NamedTuple[(tr=tr,)]
    @test combinedargs(MakeTreatCols(), allntargs) == (Set([-1]),)
    push!(allntargs, allntargs[1])
    @test combinedargs(MakeTreatCols(), allntargs) == (Set([-1]),)
    push!(allntargs, (tr=dynamic(:wave, [-1,-2]),))
    @test combinedargs(MakeTreatCols(), allntargs) == (Set([-1]),)
    push!(allntargs, (tr=dynamic(:wave, [-3]),))
    @test combinedargs(MakeTreatCols(), allntargs) == (Set{Int}(),)

    nt = merge(nt, (tr=tr,))
    @test MakeTreatCols()(nt) == merge(nt, (itreats=ret.itreats, treatcols=ret.treatcols,
        cellweights=ret.cellweights, cellcounts=ret.cellcounts))
end

@testset "SolveLeastSquares" begin
    hrs = exampledata("hrs")
    nobs = size(hrs, 1)
    tr = dynamic(:wave, -1)
    yxcols0 = Dict(term(:oop_spend)=>hrs.oop_spend, term(1)=>ones(nobs, 1))
    col0 = convert(Vector{Float64}, (hrs.wave_hosp.==10).&(hrs.wave.==10))
    col1 = convert(Vector{Float64}, (hrs.wave_hosp.==10).&(hrs.wave.==11))
    tcols0 = Dictionary([(rel=0, wave_hosp=10), (rel=1, wave_hosp=10)], [col0, col1])
    nt = (tr=tr, yterm=term(:oop_spend), xterms=(term(1),), yxcols=yxcols0, treatcols=tcols0)
    ret, share = solveleastsquares(nt...)
    # Compare estimates with Stata
    @test ret.coef[1] ≈ 2862.4141 atol=1e-4
    @test ret.coef[2] ≈ 490.44869 atol=1e-4
    @test ret.coef[3] ≈ 3353.6565 atol=1e-4
    @test ret.basecols == trues(3)
    @test ret.treatinds.rel == [0, 1]
    @test ret.treatinds.wave_hosp == [10, 10]

    # Test colliner xterms are handled
    yxcols1 = Dict(term(:oop_spend)=>hrs.oop_spend, term(1)=>ones(nobs),
        term(2)=>fill(2.0, nobs))
    nt1 = merge(nt, (xterms=(term(1), term(2)), yxcols=yxcols1))
    ret1, share = solveleastsquares(nt1...)
    @test ret1.coef[1:2] == ret.coef[1:2]
    @test sum(ret1.basecols) == 3

    insert!(tcols0, (rel=1, wave_hosp=0), ones(nobs))
    nt1 = merge(nt1, (treatcols=tcols0,))
    @test_throws ErrorException solveleastsquares(nt1...)
    delete!(tcols0, (rel=1, wave_hosp=0))
    
    res = SolveLeastSquares()(nt)
    @test res.coef == ret.coef
end
