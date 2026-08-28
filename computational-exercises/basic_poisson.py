import firedrake as fd
from firedrake.output import VTKFile

# Finite element mesh
Nx, Ny = 32, 32
Lx, Ly = 1.0, 1.0
msh = fd.RectangleMesh(Nx, Ny, Lx, Ly, quadrilateral=False)

# Space of functions
Vd = fd.FunctionSpace(msh, "CG", degree=1)

# Test and Trial functions
u  = fd.TrialFunction(Vd)
v  = fd.TestFunction(Vd)

# Boundary conditions
u_boundary = fd.Constant(0.0)
bc = fd.DirichletBC(Vd, u_boundary, "on_boundary")

# Source term
f  = fd.Constant(1.0)

x  = fd.SpatialCoordinate(msh)
mu = fd.Constant(1.0) # this could be a function of x

# Bilinear form (lhs) and linear form (rhs)
a  = fd.inner(mu * fd.grad(u), fd.grad(v)) * fd.dx
L  = fd.inner(f, v) * fd.dx

# Solve the problem
ud = fd.Function(Vd)
opts={"ksp_type": "preonly", "pc_type": "lu"}
fd.solve(a==L, ud, bcs=[bc], solver_parameters=opts)

# Visualize in paraview
ud.rename = "mySolution"
VTKFile("SolPoisson.pvd").write(ud)


