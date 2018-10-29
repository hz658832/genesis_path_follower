# Code to test the quality of the trained nets for Longitudinal control
# GXZ + MB

using MAT
using Gurobi
using JuMP


#### problem paramters for LONGITUDINAL Control 
# Global variable LOAD_PATH contains the directories Julia searches for modules when calling require. It can be extended using push!:
push!(LOAD_PATH, "../scripts/mpc_utils") 	
import GPSKinMPCPathFollowerFrenetLinLongGurobi
import KinMPCParams
const kmpcLinLong = GPSKinMPCPathFollowerFrenetLinLongGurobi  # short-hand-notation


# Load as Many parameters as possible from MPC file to avoid parameter mis-match
N 		= KinMPCParams.N
dt 		= KinMPCParams.dt
nx 		= 2								# dimension of x = (ey,epsi)
nu 		= 1								# number of inputs u = df
L_a 	= KinMPCParams.L_a				# from CoG to front axle (according to Jongsang)
L_b 	= KinMPCParams.L_b				# from CoG to rear axle (according to Jongsang)

############## load all NN Matrices ##############
dualNN_Data 	= matread("../catkin_ws/src/genesis_path_follower/paths/dummyMatNN_DualLong.mat")
primalNN_Data 	= matread("../catkin_ws/src/genesis_path_follower/paths/dummyMatNN_PrimLong.mat")
# read out NN primal/Dual weights
Wi_PLong = primalNN_Data["Wi_PLong"]
bi_PLong = primalNN_Data["bi_PLong"]
W1_PLong = primalNN_Data["W1_PLong"]
b1_PLong = primalNN_Data["b1_PLong"]
Wout_PLong = primalNN_Data["Wout_PLong"]
bout_PLong = primalNN_Data["bout_PLong"]

Wi_DLong = dualNN_Data["Wi_DLong"]
bi_DLong = dualNN_Data["bi_DLong"]
W1_DLong = dualNN_Data["W1_DLong"]
b1_DLong = dualNN_Data["b1_DLong"]
Wout_DLong = dualNN_Data["Wout_DLong"]
bout_DLong = dualNN_Data["bout_DLong"]
############################################################################

## Load Ranges of params 

 v_lb = KinMPCParams.v_min 
 v_ub = KinMPCParams.v_max
 aprev_lb = -KinMPCParams.a_max
 aprev_ub =  KinMPCParams.a_max

# input reference
u_ref_init = kmpcLinLong.u_ref_init									# if not used, set cost to zeros

# ================== Transformation 1 =======================
# augment state and redefine system dynamics (A,B,g) and constraints
# x_tilde_k := (x_k , u_{k-1})
# u_tilde_k := (u_k - u_{k-1})

A_tilde = kmpcLinLong.A_tilde
B_tilde = kmpcLinLong.B_tilde
g_tilde = kmpcLinLong.g_tilde

x_tilde_lb = kmpcLinLong.x_tilde_lb
x_tilde_ub = kmpcLinLong.x_tilde_ub
u_tilde_lb = kmpcLinLong.u_tilde_lb
u_tilde_ub = kmpcLinLong.u_tilde_ub

Q_tilde = kmpcLinLong.Q_tilde
R_tilde = kmpcLinLong.R_tilde


# build equality matrix (most MALAKA task ever)
nu_tilde = kmpcLinLong.nu_tilde
nx_tilde = kmpcLinLong.nx_tilde

Q_tilde_vec = kron(eye(N),Q_tilde)   # for x_tilde_vec
R_tilde_vec = kron(eye(N),R_tilde)	 # for u_tilde_vec

A_tilde_vec = zeros(N*(nx+nu), (nx+nu))
for ii = 1 : N
    A_tilde_vec[1+(ii-1)*(nx+nu):ii*(nx+nu),:] = A_tilde^ii
end

B_tilde_vec = zeros(N*(nx+nu), nu*N)
for ii = 0 : N-1
    for jj = 0 : ii-1
        B_tilde_vec[1+ii*(nx+nu):(ii+1)*(nx+nu), 1+jj*nu:  (jj+1)*nu] = A_tilde^(ii-jj)*B_tilde
    end
    B_tilde_vec[1+ii*(nx+nu):(ii+1)*(nx+nu), 1+ii*nu:(ii+1)*nu] = B_tilde
end

nw=nx+nu
E_tilde_vec = zeros(N*(nx+nu), nw*N)

for ii = 0 : N-1
    for jj = 0 : ii-1
        E_tilde_vec[1+ii*(nx+nu):(ii+1)*(nx+nu), 1+jj*nw:  (jj+1)*nw] = A_tilde^(ii-jj)*eye(nx+nu)
    end
    E_tilde_vec[1+ii*(nx+nu):(ii+1)*(nx+nu), 1+ii*nw:(ii+1)*nw] = eye(nx+nu)
end

g_tilde_vec = repmat(g_tilde,N)


u_ref_init = zeros(N,1)	# if not used, set cost to zeros

# build constraints
Fu_tilde = [eye(nu) ; -eye(nu)]
fu_tilde = [u_tilde_ub; -u_tilde_lb]
ng = length(fu_tilde)
# Concatenate input (tilde) constraints
Fu_tilde_vec = kron(eye(N), Fu_tilde)
fu_tilde_vec = repmat(fu_tilde,N)

# Appended State constraints (tilde)
F_tilde = [eye(nx+nu) ; -eye(nx+nu)]
f_tilde = [x_tilde_ub ; -x_tilde_lb]
nf = length(f_tilde);
 
# Concatenate appended state (tilde) constraints
F_tilde_vec = kron(eye(N), F_tilde)
f_tilde_vec = repmat(f_tilde,N)   

Q_dual = 2*(B_tilde_vec'*Q_tilde_vec*B_tilde_vec + R_tilde_vec);
C_dual = [F_tilde_vec*B_tilde_vec; Fu_tilde_vec]					# Adding state constraints 
Qdual_tmp = C_dual*(Q_dual\(C_dual'))
Qdual_tmp = 0.5*(Qdual_tmp+Qdual_tmp') + 0e-5*eye(N*(nf+ng))
    

######################## Functions to Evaluate the NNs now ########################################

function eval_DualNN(params::Array{Float64,1})
		global x_tilde_ref

		x_tilde_0 = params[1:3]
		
		# some terms can be pre-computed
		c_dual = (2*x_tilde_0'*A_tilde_vec'*Q_tilde_vec*B_tilde_vec + 2*g_tilde_vec'*E_tilde_vec'*Q_tilde_vec*B_tilde_vec +
    	      - 2*x_tilde_ref'*Q_tilde_vec*B_tilde_vec)'

		const_dual = x_tilde_0'*A_tilde_vec'*Q_tilde_vec*A_tilde_vec*x_tilde_0 + 2*x_tilde_0'*A_tilde_vec'*Q_tilde_vec*E_tilde_vec*g_tilde_vec +
                  + g_tilde_vec'*E_tilde_vec'*Q_tilde_vec*E_tilde_vec*g_tilde_vec +
                  - 2*x_tilde_0'*A_tilde_vec'*Q_tilde_vec*x_tilde_ref - 2*g_tilde_vec'*E_tilde_vec'*Q_tilde_vec*x_tilde_ref +
                  + x_tilde_ref'*Q_tilde_vec*x_tilde_ref
        
	    d_dual = [f_tilde_vec - F_tilde_vec*A_tilde_vec*x_tilde_0 - F_tilde_vec*E_tilde_vec*g_tilde_vec;  fu_tilde_vec]

   		# calls the NN with two Hidden Layers
		z1 = max.(Wi_DLong*params + bi_DLong, 0)
		z2 = max.(W1_DLong*z1 + b1_DLong, 0)
		lambda_tilde_NN_orig = Wout_DLong*z2 + bout_DLong
		lambda_tilde_NN_vec = max.(Wout_DLong*z2 + bout_DLong, 0)  	#Delta-Acceleration

		dualObj_NN = -1/2 * lambda_tilde_NN_vec'*Qdual_tmp*lambda_tilde_NN_vec - (C_dual*(Q_dual\c_dual)+d_dual)'*lambda_tilde_NN_vec - 1/2*c_dual'*(Q_dual\c_dual) + const_dual


		return dualObj_NN, lambda_tilde_NN_vec
	end


function eval_PrimalNN(params::Array{Float64,1})

		global x_tilde_ref 	# not sure if needed

		tic()

		# calls the NN with two Hidden Layers
		z1 = max.(Wi_PLong*params + bi_PLong, 0)
		z2 = max.(W1_PLong*z1 + b1_PLong, 0)
		u_tilde_NN_vec = Wout_PLong*z2 + bout_PLong  	#Delta-Acceleration

		# compute NN predicted state
		x_tilde_0 = params[1:3] 	
		x_tilde_NN_vec = A_tilde_vec*x_tilde_0 + B_tilde_vec*u_tilde_NN_vec + E_tilde_vec*g_tilde_vec

		## verify feasibility
		# xu_tilde_NN_res = [ maximum(F_tilde_vec*x_tilde_NN_vec - f_tilde_vec) ; maximum(Fu_tilde_vec*x_tilde_NN_vec - fu_tilde_vec) ]  # should be <= 0
		xu_tilde_NN_res = [ maximum(F_tilde_vec*x_tilde_NN_vec - f_tilde_vec) ; maximum(Fu_tilde_vec*u_tilde_NN_vec - fu_tilde_vec) ]  # should be <= 0
		flag_XUfeas = 0
		if maximum(xu_tilde_NN_res) < 1e-3  	# infeasible if bigger than zero/threshold
			flag_XUfeas = 1
		end

		## check optimality ##
		primObj_NN = (x_tilde_NN_vec-x_tilde_ref)'*Q_tilde_vec*(x_tilde_NN_vec-x_tilde_ref) + u_tilde_NN_vec'*R_tilde_vec*u_tilde_NN_vec
		solvTime_NN = toq()
	
		a_opt_NN = x_tilde_NN_vec[3]
		a_pred_NN = x_tilde_NN_vec[3:(nx+nu):end]
		s_pred_NN = x_tilde_NN_vec[1:(nx+nu):end]
		v_pred_NN = x_tilde_NN_vec[2:(nx+nu):end]
		# dA_pred_NN = u_tilde_NN_vec

		return primObj_NN, xu_tilde_NN_res, flag_XUfeas, a_opt_NN, a_pred_NN, s_pred_NN, v_pred_NN, u_tilde_NN_vec, solvTime_NN
	
	end
	
######################## ITERATE OVER parameters ################
# build problem
num_DataPoints = 10000						# Number of test data points
solv_time_all = zeros(num_DataPoints)
dual_gap = zeros(num_DataPoints)
Reldual_gap = zeros(num_DataPoints)
PrimandOnline_gap = zeros(num_DataPoints)
RelPrimandOnline_gap = zeros(num_DataPoints)
optVal_long = zeros(num_DataPoints)


dual_Fx = []
dual_Fu = []
L_test_opt = []
s_ub_ref = zeros(1,N)
ii = 1

for refC = 1:N
	s_ub_ref[1,refC] = 3 + 2*(refC-1) 					# Increments of 2 along horizon 
end

while ii <= num_DataPoints
	
	# Save only feasible points. 
	# extract appropriate parameters	
 	s_0 = -1 + 2*rand(1)										# Normalized to 0 now apparently  
 	v_0 = v_lb + (v_ub-v_lb)*rand(1) 
 	u_0 = aprev_lb + (aprev_ub-aprev_lb)*rand(1) 		
	s_ref = rand(1)*s_ub_ref									# Vary along horizon 
 	v_ref = v_lb + (v_ub-v_lb)*rand(1,N)				

 	x_ref = zeros(N*nx,1)
	for i = 1 : N
		x_ref[(i-1)*nx+1] = s_ref[i]		# set x_ref, s_ref/v_ref is of dim N+1; index of s_ref changed
		x_ref[(i-1)*nx+2] = v_ref[i]		# set v_ref
	end
	x_tilde_ref = zeros(N*(nx+nu))
	for i = 1 : N
		x_tilde_ref[(i-1)*(nx+nu)+1 : (i-1)*(nx+nu)+nx] = x_ref[(i-1)*nx+1 : (i-1)*nx+nx]
		x_tilde_ref[(i-1)*(nx+nu)+nx+1 : (i-1)*(nx+nu)+nx+nu] = u_ref_init[i]	# u_ref_init always 0, but no no weights
	end

	x0 = [s_0 ; v_0]
	u0 = u_0 				# it's really u_{-1}
	x_tilde_0 = [x0 ; u0]	# initial state of system; PARAMETER

 
 	# stack everything together
	params = [s_0 ; v_0 ; u_0 ; s_ref[2:end] ; v_ref[2:end]] 	# stack to 19x1 matrix

	# eval NN solutions
	primNN_obj, xu_tilde_NN_res, flag_XUfeas, a_opt_NN, a_pred_NN, s_pred_NN, v_pred_NN, dA_pred_NN, solvTime_NN = eval_PrimalNN(params)
	dualNN_obj, lambda_tilde_NN_vec = eval_DualNN(params)

	
	# solve primal problem
	# use it to test consistency
	mdl = Model(solver=GurobiSolver(Presolve=0, LogToConsole=0))
	@variable(mdl, x_tilde_vec[1:N*(nx+nu)])  	# decision variable; contains everything
	@variable(mdl, u_tilde_vec[1:N*nu] )
	@objective(mdl, Min, (x_tilde_vec-x_tilde_ref)'*Q_tilde_vec*(x_tilde_vec-x_tilde_ref) + u_tilde_vec'*R_tilde_vec*u_tilde_vec)
	constr_eq = @constraint(mdl, x_tilde_vec .== A_tilde_vec*x_tilde_0 + B_tilde_vec*u_tilde_vec + E_tilde_vec*g_tilde_vec)
	constr_Fx = @constraint(mdl, F_tilde_vec*x_tilde_vec .<= f_tilde_vec)
	constr_Fu = @constraint(mdl, Fu_tilde_vec*u_tilde_vec .<= fu_tilde_vec)

	tic()
	status = solve(mdl)
	obj_primal = getobjectivevalue(mdl)

 	if !(status == :Optimal)
 		@goto label1 
 	end

	optVal_long[ii] = obj_primal
	solv_time_all[ii] = toq()
	
	PrimandOnline_gap[ii] = primNN_obj - obj_primal
	RelPrimandOnline_gap[ii] = PrimandOnline_gap/obj_primal
 	###########################################################	

	dual_gap[ii] = primNN_obj - dualNN_obj
	Reldual_gap[ii] = dual_gap/obj_primal

	##

 	ii = ii + 1 

 	@label label1
end


println("===========================================")
println("max dual_gap:  $(maximum(dual_gap))")
println("min dual_gap:  $(minimum(dual_gap))")
println("max Rel dual_gap:  $(minimum(Reldual_gap))")
println("min Rel dual_gap:  $(minimum(Reldual_gap))")
println("max onlineNN_gap:  $(maximum(PrimandOnline_gap))")
println("min onlineNN_gap:  $(minimum(PrimandOnline_gap))")
println("max Rel onlineNN_gap:  $(minimum(RelPrimandOnline_gap))")
println("min Rel onlineNN_gap:  $(minimum(RelPrimandOnline_gap))")





