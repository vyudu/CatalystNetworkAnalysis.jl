"""
    ispersistent(rs::ReactionSystem)

    Checks if a reaction system is persistent, meaning that none of its species with positive concentration will go extinct (asymptotically approach 0). 
"""

function ispersistent(rs::ReactionSystem)
    siphons = minimalsiphons(rs)
    conservative = isconservative(rs)
    consistent = isconsistent(rs)
    conslaws = conservationlaws(rs)

    # Conservative case
    if conservative
        all(s -> !iscritical(s, conslaws), siphons) && return true
        !consistent && return false
    end

    error("The persistence test is inconclusive; this function currently cannot determine whether this network is persistent or not.")
end


"""
    minimalsiphons(rs::ReactionSystem)

    Constructs the set of minimal siphons of a reaction network, where a siphon is a set of species that can be "switched off," i.e. if the species each have concentration 0, the concentration of all the species will remain 0 for all time. A minimal siphon is one that does not contain a siphon as a strict subset.
"""

function minimalsiphons(rs::ReactionSystem; algorithm = :SMT)
    if algorithm == :SMT
        return minimalsiphons_smt(rs)
    elseif algorithm == :ALG
        return minimalsiphons_alg(rs)
    else
        error("Invalid algorithm specified")
    end
end

function minimalsiphons_smt(rs::ReactionSystem)
    ns = numspecies(rs)
    sm = speciesmap(rs)

    # We encode the problem as a Boolean satisfiability problem. In a siphon search, species that belong to the siphon have a value of 1, and those that do not have a value of 0
    @satvariable(specs[1:ns], Bool)

    # Our initial constraint requires that there is at least one element in the siphon. 
    constraints = [or(specs)]
    siphons = Array{Int}[]

    # Each reaction adds some constraint to our satisfiability problem. 
    for rx in reactions(rs)
        # Determine substrate and product species for the given reaction. 
        subs = rx.substrates
        prods = rx.products
        sub_idx = [sm[sub] for sub in subs]
        prod_idx = [sm[prod] for prod in prods]

        # Add constraints as such: 
        # If the reaction has ∅ as a substrate complex, then it cannot be a member of a siphon. 
        # If s is produced by the reaction, then s = 1 implies that there is some species in the substrate complex that is also equal to 1. 
        
        for p in prod_idx
            if isempty(subs)
                cons = not(specs[p])
            else
                cons = implies(specs[p], or([specs[s] for s in sub_idx]))
            end
            push!(constraints, cons)
        end
    end

    # Solve the CSP to find a siphon. 
    status = sat!(constraints..., solver = Z3())

    # Any time we find a siphon, we must add another constraint in order to ensure that the siphons are minimal. To disallow 
    while status == :SAT
        siphon = findall(Satisfiability.value(specs))
        push!(siphons, siphon)
        push!(constraints, or(not.(specs[siphon])))
        status = sat!(constraints..., solver = Z3())
    end

    return removesupersets(siphons)
end

function removesupersets(indexsets::AbstractArray{<:Array})
    indexsets = sort(indexsets, by=x->length(x))
    minimalsets = Array[]

    for s in indexsets
        if !any(ms->issubset(ms, s), minimalsets)
            push!(minimalsets, s)
        end
    end
    return minimalsets
end

# TODO: Check if this can handle open reaction networks
function minimalsiphons_alg(rs::ReactionSystem)
    sm = speciesmap(rs)
    specs = species(rs)
    complexes, D = reactioncomplexes(rs)
    rxns = reactions(rs)

    R, vars = polynomial_ring(QQ, string.(species(rs)))

    cm = []
    for c in complexes
        if isempty(c)
            push!(cm, 0)
        else
            monomial = prod([vars[rce.speciesid]^rce.speciesstoich for rce in c])
            push!(cm, monomial)
        end
    end

    ideal_generators = []
    for r = 1:length(rxns)
        s = findfirst(==(-1), @view D[:, r])
        p = findfirst(==(1), @view D[:, r])
        polynomial = cm[s] * (cm[p] - cm[s])
        push!(ideal_generators, polynomial)
    end
    I = ideal(R, ideal_generators)

    siphons = [indexin(gens(prime), vars) for prime in minimal_primes(I)]
end

"""
    iscritical(s, conslaws)

    Checks if a siphon is critical, meaning that it does not contain the support of some conservation law. A reaction network with a critical siphon cannot be persistent.
"""
function iscritical(s::Vector, conslaws)
    supports = [findall(!=(0), conslaws[i, :]) for i = 1:size(conslaws, 1)]

    # If the support of any non-negative conservation law is contained in the siphon, then it is not critical
    all(sup -> !issubset(sup, s), supports)
end

"""
    cycles(rs::ReactionSystem)

    Returns the matrix of cycles (or flux vectors), or reaction fluxes at steady state. These correspond to right eigenvectors of the stoichiometric matrix. Equivalent to [`fluxmodebasis`](@ref). 
"""

function cycles(rs::ReactionSystem)
    # nps = get_networkproperties(rs)
    nsm = netstoichmat(rs)
    cycles(nsm)
    # !isempty(nps.cyclemat) && return nps.cyclemat
    # nps.cyclemat = cycles(nsm; col_order = nps.col_order)
    # nps.cyclemat
end

function cycles(nsm::T; col_order = nothing) where {T<:AbstractMatrix}

    # compute the left nullspace over the integers
    N = MT.nullspace(nsm; col_order)

    # if all coefficients for a cycle are negative, make positive
    for Nrow in eachcol(N)
        all(r -> r <= 0, Nrow) && (Nrow .*= -1)
    end

    # check we haven't overflowed
    iszero(nsm * N) || error(
        "Calculation of the cycle matrix was inaccurate, " *
        "likely due to numerical overflow. Please use a larger integer " *
        "type like Int128 or BigInt for the net stoichiometry matrix.",
    )

    T(N)
end

"""
    isconsistent(rs::ReactionSystem)

    Checks if a reaction network is consistent, i.e. admits a positive equilibrium for some choice of rate constants. Equivalent to [`ispositivelydependent`](@ref).
"""
function isconsistent(rs::ReactionSystem)
    cyclemat = cycles(rs)
    n, m = size(cyclemat)

    for i = 1:m
        all(>(0), @view cyclemat[:, i]) && return true
    end

    model = Model(HiGHS.Optimizer)
    set_silent(model)
    @variable(model, coeffs[1:m])
    @objective(model, Min, 0)
    @constraint(model, cyclemat * coeffs >= ones(n))

    optimize!(model)
    is_solved_and_feasible(model) ? true : false
end


"""
    isconservative(rs::ReactionSystem)

    Checks if a reaction network is conservative, i.e. admits a positive linear conserved quantity. A positive linear conserved quantity is one for which the coefficient of each species is greater than zero. 
"""
function isconservative(rs::ReactionSystem)
    conslaws = conservationlaws(rs)
    n, m = size(conslaws)

    for i = 1:n
        all(>(0), @view conslaws[i, :]) && return true
    end

    model = Model(HiGHS.Optimizer)
    set_silent(model)
    @variable(model, coeffs[1:n])
    @objective(model, Min, 0)
    @constraint(model, conslaws' * coeffs >= ones(m))

    optimize!(model)
    is_solved_and_feasible(model) ? true : false
end

"""
    ispositivelydependent(rs::ReactionSystem)

    See documentation for [`isconsistent`](@ref).
"""
function ispositivelydependent(rs::ReactionSystem)
    isconsistent(rs)
end
