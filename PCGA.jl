module PCGA
using Debug

# Julia implementation of PCGA, a method for solving the
# subsurface inverse problems using a randomized low rank approximation of
# the prior covariance, and a finite difference approximation of the
# gradient. No adjoints, gradients, or Hessians required.  
# Last updated Aug 6, 2015 by Ellen Le
# Questions: ellenble@gmail.com

# References: 
# Jonghyun Lee and Peter K. Kitanidis, 
# Large-Scale Hydraulic Tomography and Joint Inversion of Head and
# Tracer Data using the Principal Component Geostatistical Approach
# (PCGA), 
# Water Resources Research, 50(7): 5410-5427, 2014
# Peter K. Kitanidis and Jonghyun Lee, 
# Principal Component Geostatistical Approach for Large-Dimensional
# Inverse Problem, 
# Water Resources Research, 50(7): 5428-5443, 2014

const delta = sqrt(eps())

function colnorms(Y)
    norms = Array(Float64, size(Y, 2))
    for i = 1:size(Y, 2)
	norms[i] = norm(Y[:, i])
    end
    return norms
end

function rangefinder(A::Matrix,l::Int64,its::Int64)
    srand(1)
    m = size(A, 1)
    n = size(A, 2)
    Omega = randn(n, l) #Gaussian requires less oversampling but is more
    #costly to construct, see sect 4.6 Halko
    Y = A*Omega

    if its == 0
        Q,R,() = qr(Y,pivot = true); #pivoted QR is more numerically
        #stable
    end
    
    if its > 0
        Q,R = lu(Y)
    end

    #   Conduct normalized power iterations.
    #
    for it = 1:its

        Q = (Q'*A)';

        Q,R = lu(Q);

        Q = A*Q;

        if it < its
            Q,R = lu(Q);
        end

        if it == its
            Q,R,() = qr(Q,pivot = true);
        end

    end

    return Q
end

function randSVDzetas(A::Matrix,K::Int64,p::Int64,q::Int64)
    Q = rangefinder(A,K+p,q);
    B = Q' * A;      # 
    (),S,V = svd(B); #This is algorithm 5.1, Direct SVD
    Sh = diagm(sqrt([S[1:K];zeros(p)])) # Cut back to K from K+p
    Z = V*Sh 
    return Z
end  


function rgaiteration(initialforwardmodel::Function,s0::Vector, X::Vector,
                              xis::Array{Array{Float64, 1}, 1}, R::Matrix,
                              y::Vector,strue::Vector,S::Matrix;maxIter =
                              14,randls=false,Jtol
                              = 0.01)
    # Inputs: 
    # forwardmodel - param to obs map h(s)
    #            s - current iterate s_k or sbar          
    #            X - mean of parameter prior (replace with B*X drift matrix
    # later for p>1)
    #          xis - K columns of Z = randSVDzetas(Q,K,p,q) where Q approx= ZZ^T
    #            R - covariance of measurement error (data misfit term)
    #            y - data vector
    #        strue - the truth vectorize log K, only needed for RMSE calculations
    # Optional Args
    #       maxIter - maximum # of PCGA iterations
    #          Jtol - PCGA will quit when the cost moves less than this amount


	return pcgaiteration(x->S * initialforwardmodel(x), s0, X, xis, S * R * transpose(S), S * y, strue)
end

function pcgaiteration(forwardmodel::Function,s0::Vector, X::Vector,
                              xis::Array{Array{Float64, 1}, 1}, R::Matrix,
                              y::Vector,strue::Vector;maxIter =
                              14,randls=false,S=zeros(1,1),Jtol
                              = 0.01)
    # Inputs: 
    # forwardmodel - param to obs map h(s)
    #            s - current iterate s_k or sbar          
    #            X - mean of parameter prior (replace with B*X drift matrix
    # later for p>1)
    #          xis - K columns of Z = randSVDzetas(Q,K,p,q) where Q approx= ZZ^T
    #            R - covariance of measurement error (data misfit term)
    #            y - data vector
    #        strue - the truth vectorize log K, only needed for RMSE calculations
    # Optional Args
    #       maxIter - maximum # of PCGA iterations
    #          Jtol - PCGA will quit when the cost moves less than this amount


    global delta
    p = 1
    K = length(xis)
    m = length(s0)
    n = length(y)

    RMSE = Array(Float64,maxIter+1)
    sbar  = Array(Float64,length(strue),maxIter+1)
    sbar[:,1] = s0;
    s = s0;
    RMSE[1] = norm(sbar[:,1]-strue)*(1/sqrt(m))
    cost = Array(Float64, maxIter)

    converged = false
    iterCt = 0

    hs = forwardmodel(s)

    while ( ~converged && iterCt < maxIter )

        paramstorun = Array(Array{Float64, 1}, length(xis) + 2)
        
        for i = 1:length(xis)
	    paramstorun[i] = s + delta * xis[i]
        end
        
        paramstorun[K + 1] = s + delta * X
        paramstorun[K + 2] = s + delta * s
        
        results = pmap(forwardmodel, paramstorun) 

        HQH = zeros(n,n)
        HQ = zeros(n, m)
        for i = 1:K
	    etai = (results[i] - hs) / delta
       	    HQ += etai * transpose(xis[i])
	    HQH += etai * transpose(etai)
        end
        HX = (results[K+1] - hs) / delta
        Hs = (results[K+2] - hs) / delta
        
        HQHpR = HQH+R 
        bigA = [HQHpR HX; transpose(HX) zeros(p, p)];
        b = [y - hs + Hs; zeros(p)];
        if randls == true
            bigAp = S*bigA
            bp = S*b
            x = pinv(bigAp)*(bp)
        else
            x = pinv(bigA) * b
        end
        beta_bar = x[end]
        xi_bar = x[1:end-1]
        sbar[:,iterCt+2] = X * beta_bar + (HQ)'* xi_bar
        RMSE[iterCt+2] = norm(sbar[:,iterCt+2]-strue)*(1/sqrt(m))
        s = sbar[:,iterCt+2]
        
        iterCt += 1
        
        hs = forwardmodel(s)
        cost[iterCt] = 0.5*dot(y-hs,R\(y-hs)) + 0.5*dot(xi_bar,HQH*xi_bar)

        if iterCt>1 
            # Check convergence criteria
            costchange = cost[iterCt-1]-cost[iterCt]
            if costchange<0
                println("cost is increasing")
            elseif costchange<Jtol
                converged = true
                println("cost not changing, converged")
            end     
        end
    end    
    return sbar,RMSE,cost,iterCt
end


#@debug function pcgaiteration(forwardmodel::Function,s0::Vector,
#X::Vector,
function pcgaiterationlm(forwardmodel::Function,s0::Vector, X::Vector,
                              xis::Array{Array{Float64, 1}, 1}, R::Matrix,
                              y::Vector,strue::Vector;maxIter =
                              14,lmoption=1,randls=false,S=zeros(1,1),Jtol
                              = 0.01)

    
    maxStep = 35
    lambda = 0.5 # 1 is same as reg PCGA
    lambdadown = 0.5
    lambdaup = 2
    gamma = 1.1
    tau = 1 - (1+lambda)^-gamma

        global delta
        p = 1
        K = length(xis)
        m = length(s0)
        n = length(y)

        RMSE = Array(Float64,maxIter+1)
        sbar  = Array(Float64,length(strue),maxIter+1)
        sbar[:,1] = s0;
        s = s0;
        RMSE[1] = norm(sbar[:,1]-strue)*(1/sqrt(m))
        cost = Array(Float64, maxIter)

        converged = false
        iterCt = 0

        hs = forwardmodel(s)

        while ( ~converged && iterCt < maxIter )

            paramstorun = Array(Array{Float64, 1}, length(xis) + 2)
            
            for i = 1:length(xis)
	        paramstorun[i] = s + delta * xis[i]
            end
            
            paramstorun[K + 1] = s + delta * X
            paramstorun[K + 2] = s + delta * s
            
            results = pmap(forwardmodel, paramstorun) 

            HQH = zeros(n,n)
            HQ = zeros(n, m)
            for i = 1:K
	        etai = (results[i] - hs) / delta
       	        HQ += etai * transpose(xis[i])
	        HQH += etai * transpose(etai)
            end
            HX = (results[K+1] - hs) / delta
            Hs = (results[K+2] - hs) / delta
            
            HQHpR = HQH+R 

            if lmoption == 0
                bigA = [HQHpR HX; transpose(HX) zeros(p, p)];
                b = [y - hs + Hs; zeros(p)];

                if randls == true
                    bigAp = S*bigA
                    bp = S*b
                    x = pinv(bigAp)*(bp)
                else
                    x = pinv(bigA) * b
                end
                
                beta_bar = x[end]
                xi_bar = x[1:end-1]

            elseif lmoption == 1

                # bigA = [HQHpR HX; transpose(HX) zeros(p, p)];
                # b = [y - hs + Hs; zeros(p)];
                # x = pinv(bigA) * b

                # beta_bar2 = x[end]
                # xi_bar2 = x[1:end-1]
                # sbar2 = X*beta_bar2 + (HQ)'* xi_bar2

                bigA_in = [(HQH + lambda*R) HX; HX' zeros(p,p)]
                b_in = [y - hs; zeros(p)]
                
                bigA_pr = [(HQH - tau*R) HX; HX' zeros(p,p)]
                b_pr = [Hs; zeros(p)]   
                
                x_in = pinv(bigA_in)*b_in
                x_pr = pinv(bigA_pr)*b_pr

                xi_in = x_in[1:end-1]
                beta_in = x_in[end]
                xi_pr = x_pr[1:end-1]
                beta_pr = x_pr[end]
                
                beta_bar = beta_in + beta_pr
                xi_bar = xi_in + xi_pr

                sbar[:,iterCt+2] = X*beta_bar + (HQ)'* xi_bar
#@bp

            end

            dels = norm(sbar[:,iterCt+2]-s)
            RMSE[iterCt+2] = norm(sbar[:,iterCt+2]-strue)*(1/sqrt(m))
            s = sbar[:,iterCt+2]
            
            iterCt += 1
            
            hs = forwardmodel(s)
            cost[iterCt] = 0.5*dot(y-hs,R\(y-hs)) + 0.5*dot(xi_bar,HQH*xi_bar)

            if iterCt>1 
                # Check convergence criteria
                costchange = cost[iterCt-1]-cost[iterCt]
                if (dels > maxStep || costchange < 0)
                    dels > maxStep && println("step too large, lambda increased at iteration $(iterCt)")
                    costchange < 0 && println("cost is increasing,lambda increased at iteration $(iterCt)")
                    lambda = lambda*lambdaup
                elseif costchange<Jtol
                    converged = true
                    println("cost not changing, converged")
                else
                    lambda = lambda*lambdadown
                    println("lambda decreasing")
                end     
            elseif iterCt>1
                dels <= maxStep && (lambda = lambda*lambdadown)
                dels > maxStep && (lambda = lambda*lambdaup) && println("step too large, increasing lambda at step 1")
            end
            tau = 1 - (1+lambda)^-gamma

        end    
    
        return sbar,RMSE,cost,iterCt
end

end


