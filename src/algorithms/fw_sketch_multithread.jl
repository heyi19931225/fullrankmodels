### Fit a full rank model with sketched Frank Wolfe

# todo: make it work for mpca

import FirstOrderOptimization: frank_wolfe_sketched, FrankWolfeParams, DecreasingStepSize,
                               AbstractSketch, AsymmetricSketch,
                               IndexingOperator, LowRankOperator,
                               IndexedLowRankOperator, mysvds
import LowRankModels: fit!, ConvergenceHistory, get_yidxs, grad, evaluate
import Base: axpy!, scale!

export fit!, FrankWolfeParams

### FITTING
function fit!(gfrm::GFRM, params::FrankWolfeParams = FrankWolfeParams();
			  ch::ConvergenceHistory=ConvergenceHistory("FrankWolfeGFRM"),
        z::AbstractVector = zeros(sum(map(length, gfrm.observed_examples))),
        sketch::AbstractSketch = AsymmetricSketch(size(gfrm.A)..., gfrm.k),
        fenchel_tol::Float64 = 1e-5,
			  verbose=true,
			  kwargs...)

    if !isa(gfrm.r, TraceNormConstraint)
        error("Frank Wolfe fitting is only implemented for trace norm constrained problems")
    end

    # the functions below close over all this problem data
    yidxs = get_yidxs(gfrm.losses)
    d = maximum(yidxs[end])
    m,n = size(gfrm.A)
    alpha = gfrm.r.scale

    nobsj = map(length, gfrm.observed_examples)
    startobsj = cumsum(vcat(1, nobsj))
    nobs = sum(nobsj)
    obs = Array(Int, nobs)
    # iobs = 1
    Threads.@threads for j=1:n
        obs[startobsj[j]:(startobsj[j+1]-1)] = m*(j-1) + gfrm.observed_examples[j]
        # for i=gfrm.observed_examples[j]
        #     obs[iobs] = m*(j-1) + i
        #     iobs += 1
        # end
    end
    indexing_operator = IndexingOperator(m, n, obs)
    @assert size(indexing_operator, 1) == nobs
    @assert length(z) == nobs

    function f(z)
        objs = zeros(Threads.nthreads())
        # println("obj")
        # @time
        Threads.@threads for j=1:n
            objs[Threads.threadid()] +=
                evaluate(gfrm.losses[j],
                         z[startobsj[j]:(startobsj[j+1]-1)],
                         gfrm.A[gfrm.observed_examples[j],j])
        end
        return sum(objs)
    end

    ## Grad of f
    function grad_f(z;
                    g = Array(Float64, size(z)))
        iobs = 1
        # println("grad")
        # @time
        Threads.@threads for j=1:n
            ii = startobsj[j]:(startobsj[j+1]-1)
            g[ii] = grad(gfrm.losses[j], z[ii], gfrm.A[gfrm.observed_examples[j],j])
        end
        # return G = A'*g
        # LowRankOperator(indexing_operator, g, transpose = Symbol[:T, :N])
        # IndexedLowRankOperator(indexing_operator, g)
        return IndexedLowRankOperator(indexing_operator, g)
    end

    const_nucnorm(z) = alpha # we'll always saturate the constraint, don't bother computing it
    # returns solution, optval of min <G, Delta> st ||Delta||_* \leq alpha
    function min_lin_st_nucnorm_sketched(G, alpha, tol::Float64 = fenchel_tol)
        # this looks inefficient, but ga is a sparse matrix, so it's not bad
        ga = Array(G)
        # println("svds")
        # @time
        u,s,v = mysvds(ga, nsv=1, tol=tol)
        # u,s,v = mysvds(G, nsv=1) # right now there's no method to directly do svds efficiently on an IndexedLowRankOperator
        return LowRankOperator(-alpha*u, v')
    end

    # recover
    t = time()
    X_sketched = frank_wolfe_sketched(
        z,
        f, grad_f,
        const_nucnorm,
        alpha,
        min_lin_st_nucnorm_sketched,
        sketch,
        params,
        ch,
        verbose=verbose
        )

    t = time() - t
    update_ch!(ch, t, f(z))

    gfrm.W = X_sketched

    return X_sketched, ch
end
