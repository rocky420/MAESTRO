module advect_base_module

  use bl_types

  implicit none

  private

  public :: advect_base

contains

  subroutine advect_base(which_step,nlevs,vel,Sbar_in,p0_old,p0_new, &
                         s0_old,s0_new,gam1,div_coeff, &
                         s0_predicted_edge,s0_predicted_x_edge, &
                         dz,dt)

    use bl_prof_module
    use geometry, only: spherical

    integer        , intent(in   ) :: which_step,nlevs
    real(kind=dp_t), intent(in   ) :: vel(:,0:)
    real(kind=dp_t), intent(in   ) :: Sbar_in(:,0:,:)
    real(kind=dp_t), intent(in   ) :: p0_old(:,0:), s0_old(:,0:,:)
    real(kind=dp_t), intent(  out) :: p0_new(:,0:), s0_new(:,0:,:)
    real(kind=dp_t), intent(inout) :: gam1(:,0:)
    real(kind=dp_t), intent(in   ) :: div_coeff(:,0:)
    real(kind=dp_t), intent(  out) :: s0_predicted_edge(:,0:,:)
    real(kind=dp_t), intent(  out) :: s0_predicted_x_edge(:,:,:)
    real(kind=dp_t), intent(in   ) :: dz(:)
    real(kind=dp_t), intent(in   ) :: dt
    
    ! local
    integer :: n

    type(bl_prof_timer), save :: bpt

    call build(bpt, "advect_base")
    
    do n=1,nlevs
       if (spherical .eq. 0) then
          call advect_base_state_planar(which_step,n,vel(n,0:),p0_old(n,0:),p0_new(n,0:), &
                                        s0_old(n,0:,:),s0_new(n,0:,:),gam1(n,0:), &
                                        s0_predicted_edge(n,0:,:), &
                                        s0_predicted_x_edge(n,:,:),dz(n),dt)
       else
          call advect_base_state_spherical(which_step,n,vel(n,:),Sbar_in(n,:,1), &
                                           p0_old(n,:),p0_new(n,:), &
                                           s0_old(n,:,:),s0_new(n,:,:), &
                                           gam1(n,:), &
                                           s0_predicted_edge(n,0:,:),div_coeff(n,:),dt)
       end if
    enddo

    call destroy(bpt)
       
  end subroutine advect_base


  subroutine advect_base_state_planar(which_step,n,vel,p0_old,p0_new, &
                                      s0_old,s0_new,gam1, &
                                      s0_predicted_edge,&
                                      s0_predicted_x_edge,dz,dt)

    use bl_constants_module
    use make_edge_state_module
    use eos_module
    use variables, only: spec_comp, rho_comp, temp_comp, rhoh_comp
    use geometry, only: nr
    use probin_module, only: grav_const, anelastic_cutoff, predict_X_at_edges

    integer        , intent(in   ) :: which_step,n
    real(kind=dp_t), intent(in   ) :: vel(0:)
    real(kind=dp_t), intent(in   ) :: p0_old(0:), s0_old(0:,:)
    real(kind=dp_t), intent(  out) :: p0_new(0:), s0_new(0:,:)
    real(kind=dp_t), intent(inout) :: gam1(0:)
    real(kind=dp_t), intent(  out) :: s0_predicted_edge(0:,:)
    real(kind=dp_t), intent(  out) :: s0_predicted_x_edge(0:,:)
    real(kind=dp_t), intent(in   ) :: dz,dt
    
    ! Local variables
    integer :: r,comp
    integer :: r_anel
    real(kind=dp_t) :: vel_avg
    
    real (kind = dp_t), allocatable :: force(:)
    real (kind = dp_t), allocatable :: edge(:)
    real (kind = dp_t), allocatable :: X0(:)

    ! Cell-centered
    allocate(force(0:nr(n)-1))
    allocate(   X0(0:nr(n)-1))

    ! Edge-centered
    allocate(edge(0:nr(n)))
   
    s0_predicted_edge(:,:) = ZERO
    s0_predicted_x_edge(:,:) = ZERO

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! UPDATE P0
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    force = ZERO

    call make_edge_state_1d(n,p0_old,edge,vel,force,1,dz,dt)

    do r = 0, nr(n)-1
       p0_new(r) = p0_old(r) &
            - dt / dz * HALF * (vel(r) + vel(r+1)) * (edge(r+1) - edge(r)) 
    end do
    
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! UPDATE RHOX0
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

    if (predict_X_at_edges) then

       ! Predict to vertical edges
       do r = 0,nr(n)-1
          force(r) = -s0_old(r,rho_comp) * (vel(r+1) - vel(r)) / dz 
       end do
       call make_edge_state_1d(n,s0_old(:,rho_comp),edge,vel,force,1,dz,dt)
       s0_predicted_edge(:,rho_comp) = edge(:)       

       ! Predict to lateral edges
       do r = 0,nr(n)-1
          s0_predicted_x_edge(r,rho_comp) = s0_old(r,rho_comp) - &
              HALF * dt * ( vel(r+1)*edge(r+1) - vel(r)*edge(r) ) / dz 
       end do

    endif

    do comp = spec_comp,spec_comp+nspec-1

       if (predict_X_at_edges) then

          ! here we predict X_0 on the edges
          X0(:) = s0_old(:,comp)/s0_old(:,rho_comp)
          do r = 0,nr(n)-1
            X0(r) = max(X0(r),ZERO)
          end do

          force = ZERO
       
          call make_edge_state_1d(n,X0,edge,vel,force,1,dz,dt)

          ! s0_predicted_edge will store X_0 on the vertical edges -- we need
          ! that later
          s0_predicted_edge(:,comp) = edge(:)

          ! s0_predicted_x_edge will store X_0 on the horizontal edges -- we need
          ! that later
          do r = 0,nr(n)-1
             vel_avg = HALF * (vel(r)+vel(r+1))
             s0_predicted_x_edge(r,comp) = X0(r) - HALF * dt * vel_avg * &
                                                   (edge(r+1)-edge(r)) / dz
          end do
          
          ! our final update needs (rho X)_0 on the edges, so compute
          ! that now
          edge(:) = s0_predicted_edge(:,rho_comp)*edge(:)

       else

          ! here we predict (rho X)_0 on the edges
          do r = 0,nr(n)-1
             force(r) = -s0_old(r,comp) * (vel(r+1) - vel(r)) / dz 
          end do

          call make_edge_state_1d(n,s0_old(:,comp),edge,vel,force,1,dz,dt)

          ! s0_predicted_edge will store (rho X)_0 on the edges
          s0_predicted_edge(:,comp) = edge(:)

          ! compute rho_0 on the edges for completeness
          s0_predicted_edge(:,rho_comp) = s0_predicted_edge(:,rho_comp) + &
                                          s0_predicted_edge(:,comp)

          do r = 0,nr(n)-1
             s0_predicted_x_edge(r,comp) = s0_old(r,comp) + HALF*dt*force(r)
          end do

       endif

       do r = 0,nr(n)-1
          s0_new(r,comp) = s0_old(r,comp) &
               - dt / dz * (edge(r+1) * vel(r+1) - edge(r) * vel(r)) 
       end do
       
    enddo

    
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! UPDATE RHO0 FROM RHOX0
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    do r = 0,nr(n)-1
       s0_new(r,rho_comp) =  s0_old(r,rho_comp)
       do comp = spec_comp,spec_comp+nspec-1
          s0_new(r,rho_comp) =  s0_new(r,rho_comp) + (s0_new(r,comp)-s0_old(r,comp)) 
       end do
    end do
    
    
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! UPDATE RHOH0
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    do r = 0,nr(n)-1
       force(r) = -s0_old(r,rhoh_comp) * (vel(r+1) - vel(r)) / dz
    end do

    call make_edge_state_1d(n,s0_old(:,rhoh_comp),edge,vel,force,1,dz,dt)

    s0_predicted_edge(:,rhoh_comp) = edge(:)

    do r = 0,nr(n)-1
       s0_new(r,rhoh_comp) = s0_old(r,rhoh_comp) &
            - dt / dz * (edge(r+1) * vel(r+1) - edge(r) * vel(r)) 
    end do

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! MAKE TEMP0 AND GAM1 FROM P0 AND RHO0
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    do r = 0,nr(n)-1
       
       den_eos(1)  = s0_new(r,rho_comp)
       temp_eos(1) = s0_old(r,temp_comp)
       p_eos(1)    = p0_new(r)
       xn_eos(1,:) = s0_new(r,spec_comp:spec_comp+nspec-1)/s0_new(r,rho_comp)
       
       ! (rho,P) --> T, h
       call eos(eos_input_rp, den_eos, temp_eos, &
                npts, nspec, &
                xn_eos, &
                p_eos, h_eos, e_eos, &
                cv_eos, cp_eos, xne_eos, eta_eos, pele_eos, &
                dpdt_eos, dpdr_eos, dedt_eos, dedr_eos, &
                dpdX_eos, dhdX_eos, &
                gam1_eos, cs_eos, s_eos, &
                dsdt_eos, dsdr_eos, &
                do_diag)
       
       s0_new(r,temp_comp) = temp_eos(1)
       gam1(r) = gam1_eos(1)
       
    end do
    
    deallocate(force,edge,X0)
    
  end subroutine advect_base_state_planar

  
  subroutine advect_base_state_spherical(which_step,n,vel,Sbar_in, &
                                         p0_old,p0_new, &
                                         s0_old,s0_new, &
                                         gam1, &
                                         s0_predicted_edge,div_coeff_old,dt)

    use bl_constants_module
    use make_edge_state_module
    use eos_module
    use variables, only: spec_comp, rho_comp, rhoh_comp, temp_comp
    use geometry, only: nr, base_cc_loc, base_loedge_loc, dr, nr
    use make_grav_module
    use cell_to_edge_module
    use make_div_coeff_module
    
    integer        , intent(in   ) :: which_step,n
    real(kind=dp_t), intent(in   ) :: vel(0:),Sbar_in(0:)
    real(kind=dp_t), intent(in   ) :: p0_old(0:), s0_old(0:,:)
    real(kind=dp_t), intent(  out) :: p0_new(0:), s0_new(0:,:)
    real(kind=dp_t), intent(inout) :: gam1(0:)
    real(kind=dp_t), intent(  out) :: s0_predicted_edge(0:,:)
    real(kind=dp_t), intent(in   ) :: div_coeff_old(0:)
    real(kind=dp_t), intent(in   ) :: dt
    
    ! Local variables
    integer :: r,comp
    real(kind=dp_t) :: dtdr,divbetaw,betahalf,factor
    real(kind=dp_t) :: div_w0

    real (kind = dp_t), allocatable :: force(:)
    real (kind = dp_t), allocatable :: psi(:)
    real (kind = dp_t), allocatable :: edge(:)
    real (kind = dp_t), allocatable :: div_coeff_new(:)
    real (kind = dp_t), allocatable :: beta(:),beta_new(:),beta_nh(:)
    real (kind = dp_t), allocatable :: gam1_old(:)
    real (kind = dp_t), allocatable :: grav_cell(:)
    
    dtdr = dt / dr(n)
    
    ! Cell-centered
    allocate(force(0:nr(n)-1))
    allocate(gam1_old(0:nr(n)-1))
    allocate(grav_cell(0:nr(n)-1))
    allocate(div_coeff_new(0:nr(n)-1))
    allocate(psi(0:nr(n)-1))
    
    ! Edge-centered
    allocate(edge(0:nr(n)))
    allocate(beta(0:nr(n)),beta_new(0:nr(n)),beta_nh(0:nr(n)))
    
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! UPDATE RHOX0
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    do comp = spec_comp,spec_comp+nspec-1
       
       ! compute the force -- include the geometric source term that
       ! results from expanding out the spherical divergence
       do r = 0,nr(n)-1
          force(r) = -s0_old(r,comp) * (vel(r+1) - vel(r)) / dr(n) - &
               2.0_dp_t*s0_old(r,comp)*HALF*(vel(r) + vel(r+1))/base_cc_loc(n,r)
       end do
       
       call make_edge_state_1d(n,s0_old(:,comp),edge,vel,force,1,dr(n),dt)

       s0_predicted_edge(:,comp) = edge(:)

       do r = 0,nr(n)-1
          s0_new(r,comp) = s0_old(r,comp) &
               - dtdr/base_cc_loc(n,r)**2*(base_loedge_loc(n,r+1)**2*edge(r+1)*vel(r+1) &
               - base_loedge_loc(n,r  )**2 * edge(r  ) * vel(r  ))
       end do
       
    enddo
    
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! UPDATE RHO0 FROM RHOX0
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    
    do r = 0,nr(n)-1
       s0_new(r,rho_comp) =  s0_old(r,rho_comp)
       do comp = spec_comp,spec_comp+nspec-1
          s0_new(r,rho_comp) =  s0_new(r,rho_comp) + (s0_new(r,comp)-s0_old(r,comp))
       end do
    end do
    
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! UPDATE P0
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    
    ! Put beta_old on edges
    call cell_to_edge(n,div_coeff_old,beta)
    
    ! Update p0 -- predictor
    do r = 0,nr(n)-1
       divbetaw = one/(base_cc_loc(n,r)**2)*(base_loedge_loc(n,r+1)**2*beta(r+1)*vel(r+1) - &
            base_loedge_loc(n,r)**2 * beta(r) * vel(r)) / dr(n)
       betahalf = div_coeff_old(r)
       factor = half * dt * gam1(r) * (Sbar_in(r) - divbetaw / betahalf)
       p0_new(r) = p0_old(r) * (one + factor ) / (one - factor)
       
    end do
    
    do r = 0,nr(n)-1
       ! (rho, p) --> T,h, etc
       
       den_eos(1)  = s0_new(r,rho_comp)
       temp_eos(1) = s0_old(r,temp_comp) 
       p_eos(1)    = p0_new(r)
       xn_eos(1,:) = s0_new(r,spec_comp:spec_comp+nspec-1)/s0_new(r,rho_comp)
       
       gam1_old(r) = gam1(r)
       
       call eos(eos_input_rp, den_eos, temp_eos, & 
                npts, nspec, & 
                xn_eos, & 
                p_eos, h_eos, e_eos, & 
                cv_eos, cp_eos, xne_eos, eta_eos, pele_eos, &
                dpdt_eos, dpdr_eos, dedt_eos, dedr_eos, &
                dpdX_eos, dhdX_eos, &
                gam1_eos, cs_eos, s_eos, & 
                dsdt_eos, dsdr_eos, &
                do_diag) 
       
       gam1(r) = gam1_eos(1)
       s0_new(r,temp_comp) = temp_eos(1)
    end do
    
    call make_grav_cell(n,grav_cell,s0_new(:,rho_comp))
    
    ! Define beta^n+1 at cell edges using the new gravity above
    call make_div_coeff(n,div_coeff_new,s0_new(:,rho_comp),p0_new,gam1,grav_cell)
    call cell_to_edge(n,div_coeff_new,beta_new)
    
    ! time-centered beta
    beta_nh = HALF*(beta + beta_new)
    
    ! Update p0 -- corrector
    do r = 0,nr(n)-1
       divbetaw = one / (base_cc_loc(n,r)**2) &
            * (base_loedge_loc(n,r+1)**2 * beta_nh(r+1) * vel(r+1) - &
            base_loedge_loc(n,r  )**2 * beta_nh(r  ) * vel(r  ) ) / dr(n)
       betahalf = HALF*(div_coeff_old(r) + div_coeff_new(r))
       factor = half * dt * (Sbar_in(r) - divbetaw / betahalf)
       p0_new(r) = p0_old(r) * (one + factor * gam1_old(r)) / (one - factor * gam1(r))
       
    end do
    
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! UPDATE RHOH0
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

    do r = 0,nr(n)-1
       
       div_w0 = (vel(r+1) - vel(r)) / dr(n)
       
       force(r) = -s0_old(r,rhoh_comp) * div_w0 - &
            2.0_dp_t*s0_old(r,rhoh_comp)*HALF*(vel(r) + vel(r+1))/base_cc_loc(n,r)
       
       ! add psi at time-level n to the force for the prediction
       psi(r) = gam1_old(r) * p0_old(r) * (Sbar_in(r) - div_w0)
       force(r) = force(r) + psi(r)
       
       ! construct a new, time-centered psi for the final update
       psi(r) = HALF*(gam1(r)*p0_new(r) + gam1_old(r)*p0_old(r))* &
            (Sbar_in(r) - div_w0)
    end do
    
    call make_edge_state_1d(n,s0_old(:,rhoh_comp),edge,vel,force,1,dr(n),dt)

    s0_predicted_edge(:,rhoh_comp) = edge(:)
    
    do r = 0,nr(n)-1
       
       s0_new(r,rhoh_comp) = s0_old(r,rhoh_comp) - &
            dtdr / base_cc_loc(n,r)**2 * ( base_loedge_loc(n,r+1)**2 * edge(r+1) * vel(r+1) &
            -base_loedge_loc(n,r  )**2 * edge(r  ) * vel(r  ))
       
       s0_new(r,rhoh_comp) = s0_new(r,rhoh_comp) + dt * psi(r)
       
    end do
    
    
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! MAKE TEMP0 AND GAM1 FROM P0 AND RHO0
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    do r = 0,nr(n)-1
       
       den_eos(1)  = s0_new(r,rho_comp)
       temp_eos(1) = s0_new(r,temp_comp)
       p_eos(1)    = p0_new(r)
       xn_eos(1,:) = s0_new(r,spec_comp:spec_comp+nspec-1)/s0_new(r,rho_comp)
       
       ! (rho,P) --> T, h
       call eos(eos_input_rp, den_eos, temp_eos, &
                npts, nspec, &
                xn_eos, &
                p_eos, h_eos, e_eos, &
                cv_eos, cp_eos, xne_eos, eta_eos, pele_eos, &
                dpdt_eos, dpdr_eos, dedt_eos, dedr_eos, &
                dpdX_eos, dhdX_eos, &
                gam1_eos, cs_eos, s_eos, &
                dsdt_eos, dsdr_eos, &
                do_diag)
       
       s0_new(r,temp_comp) = temp_eos(1)
       gam1(r) = gam1_eos(1)
       
    end do
    
    deallocate(force,psi,edge,beta,beta_new,beta_nh,div_coeff_new,gam1_old,grav_cell)
    
  end subroutine advect_base_state_spherical
  
end module advect_base_module
