! make_edge_scal constructs the edge state of a scalar, using a
! second-order Taylor expansion in space (through dx/2) and time
! (though dt/2) (if ppm_type = 0) or using PPM (for ppm_type = 1,2).
!
! We use only MAC-projected edge velocities in this prediction.
!
! We are computing all edge states for each variable.  This is what is
! done for the final updates of the state variables and velocity.  For
! velocity, we should set is_vel = .true.

module make_edge_scal_module

  use bl_types
  use multifab_module
  use define_bc_module
  use ml_layout_module

  implicit none

  private

  public :: make_edge_scal
  
contains

  subroutine make_edge_scal(s,sedge,umac,force,dx,dt,is_vel,the_bc_level, &
                            start_scomp,start_bccomp,num_comp,is_conservative,mla)

    use bl_prof_module
    use bl_constants_module
    use fill_3d_module
    use ml_cc_restriction_module, only : ml_edge_restriction_c

    type(multifab) , intent(in   ) :: s(:)
    type(multifab) , intent(inout) :: sedge(:,:)
    type(multifab) , intent(in   ) :: umac(:,:)
    type(multifab) , intent(in   ) :: force(:)
    real(kind=dp_t), intent(in   ) :: dx(:,:),dt
    logical        , intent(in   ) :: is_vel
    type(bc_level) , intent(in   ) :: the_bc_level(:)
    integer        , intent(in   ) :: start_scomp,start_bccomp,num_comp
    logical        , intent(in   ) :: is_conservative
    type(ml_layout), intent(in   ) :: mla

    integer                  :: i,scomp,bccomp,n,dm,nlevs
    integer                  :: lo(mla%dim), hi(mla%dim)
    integer                  :: ng_s,ng_se,ng_um,ng_f
    real(kind=dp_t), pointer :: sop(:,:,:,:)
    real(kind=dp_t), pointer :: sepx(:,:,:,:)
    real(kind=dp_t), pointer :: sepy(:,:,:,:)
    real(kind=dp_t), pointer :: sepz(:,:,:,:)
    real(kind=dp_t), pointer :: ump(:,:,:,:)
    real(kind=dp_t), pointer :: vmp(:,:,:,:)
    real(kind=dp_t), pointer :: wmp(:,:,:,:)
    real(kind=dp_t), pointer :: fp(:,:,:,:)

    type(bl_prof_timer), save :: bpt

    call build(bpt, "make_edge_scal")

    dm = mla%dim
    nlevs = mla%nlevel

    ng_s  = nghost(s(1))
    ng_se = nghost(sedge(1,1))
    ng_um = nghost(umac(1,1))
    ng_f  = nghost(force(1))

    do n=1,nlevs
       do i = 1, nfabs(s(n))
          sop  => dataptr(s(n),i)
          sepx => dataptr(sedge(n,1),i)
          ump  => dataptr(umac(n,1),i)
          fp   => dataptr(force(n),i)
          lo   =  lwb(get_box(s(n),i))
          hi   =  upb(get_box(s(n),i))
          select case (dm)
          case (1)
             do scomp = start_scomp, start_scomp + num_comp - 1
                bccomp = start_bccomp + scomp - start_scomp
                call make_edge_scal_1d(sop(:,1,1,:), ng_s, &
                                       sepx(:,1,1,:), ng_se, &
                                        ump(:,1,1,1), ng_um, &
                                       fp(:,1,1,:), ng_f, &
                                       lo, hi, dx(n,:), dt, is_vel, &
                                       the_bc_level(n)%adv_bc_level_array(i,:,:,:), &
                                       scomp, bccomp, is_conservative)
             end do

          case (2)
             vmp  => dataptr(umac(n,2),i)
             sepy => dataptr(sedge(n,2),i)
             do scomp = start_scomp, start_scomp + num_comp - 1
                bccomp = start_bccomp + scomp - start_scomp
                call make_edge_scal_2d(sop(:,:,1,:), ng_s, &
                                       sepx(:,:,1,:), sepy(:,:,1,:), ng_se, &
                                       ump(:,:,1,1), vmp(:,:,1,1), ng_um, &
                                       fp(:,:,1,:), ng_f, &
                                       lo, hi, dx(n,:), dt, is_vel, &
                                       the_bc_level(n)%adv_bc_level_array(i,:,:,:), &
                                       scomp, bccomp, is_conservative)
             end do

          case (3)
             vmp  => dataptr(umac(n,2),i)
             wmp  => dataptr(  umac(n,3),i)
             sepy => dataptr(sedge(n,2),i)
             sepz => dataptr( sedge(n,3),i)
             do scomp = start_scomp, start_scomp + num_comp - 1
                bccomp = start_bccomp + scomp - start_scomp
                call make_edge_scal_3d(sop(:,:,:,:), ng_s, &
                                       sepx(:,:,:,:), sepy(:,:,:,:), sepz(:,:,:,:), &
                                       ng_se, ump(:,:,:,1), vmp(:,:,:,1), wmp(:,:,:,1), &
                                       ng_um, fp(:,:,:,:), ng_f,  &
                                       lo, hi, dx(n,:), dt, is_vel, &
                                       the_bc_level(n)%adv_bc_level_array(i,:,:,:), &
                                       scomp, bccomp, is_conservative)
             end do
          end select
       end do
    end do
    !
    ! We call ml_edge_restriction for the output velocity if is_vel .eq. .true.
    ! we do not call ml_edge_restriction for scalars because instead we will call
    ! ml_edge_restriction on the fluxes in mkflux.
    !
    if (is_vel) then
       do n = nlevs,2,-1
          do i = 1, dm
             call ml_edge_restriction_c(sedge(n-1,i),1,sedge(n,i),1,mla%mba%rr(n-1,:),i,dm)
          enddo
       enddo
    end if

    call destroy(bpt)
    
  end subroutine make_edge_scal
  
  subroutine make_edge_scal_1d(s,ng_s,sedgex,ng_se,umac,ng_um, &
                               force,ng_f,lo,hi,dx,dt,is_vel,adv_bc, &
                               comp,bccomp,is_conservative)

    use bc_module
    use slope_module
    use bl_constants_module
    use variables, only: rel_eps
    use ppm_module
    use probin_module, only: ppm_type, ppm_trace_forces

    integer        , intent(in   ) :: lo(:),hi(:),ng_s,ng_se,ng_um,ng_f
    real(kind=dp_t), intent(in   ) ::      s(lo(1)-ng_s :,:)
    real(kind=dp_t), intent(inout) :: sedgex(lo(1)-ng_se:,:)
    real(kind=dp_t), intent(in   ) ::   umac(lo(1)-ng_um:)
    real(kind=dp_t), intent(in   ) ::  force(lo(1)-ng_f :,:)
    real(kind=dp_t), intent(in   ) :: dx(:),dt
    logical        , intent(in   ) :: is_vel
    integer        , intent(in   ) :: adv_bc(:,:,:)
    integer        , intent(in   ) :: comp,bccomp
    logical        , intent(in   ) :: is_conservative

    ! Local variables
    real(kind=dp_t) :: slopex(lo(1)-1:hi(1)+1,1)

    real(kind=dp_t) :: hx,dt2,dt4,savg,fl,fr

    integer :: i,is,ie

    real(kind=dp_t), allocatable :: Ip(:), Ipf(:)
    real(kind=dp_t), allocatable :: Im(:), Imf(:)

    ! these correspond to \mathrm{sedge}_L^x, etc.
    real(kind=dp_t), allocatable:: sedgelx(:),sedgerx(:)

    allocate(Ip(lo(1)-1:hi(1)+1))
    allocate(Im(lo(1)-1:hi(1)+1))

    allocate(Ipf(lo(1)-1:hi(1)+1))
    allocate(Imf(lo(1)-1:hi(1)+1))

    ! Final edge states.
    ! lo:hi+1 in the normal direction
    ! lo:hi in the transverse direction
    allocate(sedgelx(lo(1):hi(1)+1))
    allocate(sedgerx(lo(1):hi(1)+1))

    is = lo(1)
    ie = hi(1)

    if (ppm_type .eq. 0) then
       call slopex_1d(s(:,comp:),slopex,lo,hi,ng_s,1,adv_bc(:,:,bccomp:))
    else if (ppm_type .eq. 1 .or. ppm_type .eq. 2) then
       call ppm_1d(s(:,comp),ng_s,umac,ng_um,Ip,Im,lo,hi,adv_bc(:,:,bccomp),dx,dt,.true.)
       if (ppm_trace_forces == 1) then
          call ppm_1d(force(:,comp),ng_s,umac,ng_um,Ipf,Imf,lo,hi,adv_bc(:,:,bccomp),dx,dt,.true.)
       endif
    end if

    dt2 = HALF*dt
    dt4 = dt/4.0d0

    hx = dx(1)

    !******************************************************************
    ! Create sedgelx, etc.
    !******************************************************************

    ! loop over appropriate x-faces   
    if (ppm_type .eq. 0) then
       do i=is,ie+1
          ! make sedgelx, sedgerx with 1D extrapolation
          sedgelx(i) = s(i-1,comp) + (HALF - dt2*umac(i)/hx)*slopex(i-1,1)
          sedgerx(i) = s(i  ,comp) - (HALF + dt2*umac(i)/hx)*slopex(i  ,1)
       enddo
    else if (ppm_type .eq. 1 .or. ppm_type .eq. 2) then
       do i=is,ie+1
          ! make sedgelx, sedgerx with 1D extrapolation
          sedgelx(i) = Ip(i-1)
          sedgerx(i) = Im(i  )
       end do
    end if

    ! loop over appropriate x-faces
    do i=is,ie+1
       ! make sedgelx, sedgerx
       fl = merge(force(i-1,comp), Ipf(i-1), ppm_trace_forces == 0)
       fr = merge(force(i  ,comp), Imf(i  ), ppm_trace_forces == 0)

       if(is_conservative) then
          sedgelx(i) = sedgelx(i) &
               - (dt2/hx)*s(i-1,comp)*(umac(i  )-umac(i-1)) &
               + dt2*fl
          sedgerx(i) = sedgerx(i) &
               - (dt2/hx)*s(i  ,comp)*(umac(i+1)-umac(i  )) &
               + dt2*fr
       else
          sedgelx(i) = sedgelx(i) + dt2*fl
          sedgerx(i) = sedgerx(i) + dt2*fr
       end if

       ! make sedgex by solving Riemann problem
       ! boundary conditions enforced outside of i loop
       sedgex(i,comp) = merge(sedgelx(i),sedgerx(i),umac(i) .gt. ZERO)
       savg = HALF*(sedgelx(i)+sedgerx(i))
       sedgex(i,comp) = merge(sedgex(i,comp),savg,abs(umac(i)) .gt. rel_eps)
    enddo
 
    ! impose lo side bc's
    if (adv_bc(1,1,bccomp) .eq. EXT_DIR) then
       sedgex(is,comp) = s(is-1,comp)
    else if (adv_bc(1,1,bccomp) .eq. FOEXTRAP .or. &
             adv_bc(1,1,bccomp) .eq. HOEXTRAP) then
       if (is_vel) then
          sedgex(is,comp) = min(sedgerx(is),ZERO)
       else
          sedgex(is,comp) = sedgerx(is)
       end if
    else if (adv_bc(1,1,bccomp) .eq. REFLECT_EVEN) then
       sedgex(is,comp) = sedgerx(is)
    else if (adv_bc(1,1,bccomp) .eq. REFLECT_ODD) then
       sedgex(is,comp) = ZERO
    else if (adv_bc(1,1,bccomp) .eq. INTERIOR) then
    else
       call bl_error("make_edge_scal_1d: invalid boundary type adv_bc(1,1)")
    end if

    ! impose hi side bc's
    if (adv_bc(1,2,bccomp) .eq. EXT_DIR) then
       sedgex(ie+1,comp) = s(ie+1,comp)
    else if (adv_bc(1,2,bccomp) .eq. FOEXTRAP .or. &
             adv_bc(1,2,bccomp) .eq. HOEXTRAP) then
       if (is_vel) then
          sedgex(ie+1,comp) = max(sedgelx(ie+1),ZERO)
       else
          sedgex(ie+1,comp) = sedgelx(ie+1)
       end if
    else if (adv_bc(1,2,bccomp) .eq. REFLECT_EVEN) then
       sedgex(ie+1,comp) = sedgelx(ie+1)
    else if (adv_bc(1,2,bccomp) .eq. REFLECT_ODD) then
       sedgex(ie+1,comp) = ZERO
    else if (adv_bc(1,2,bccomp) .eq. INTERIOR) then
    else
       call bl_error("make_edge_scal_1d: invalid boundary type adv_bc(1,2)")
    end if

    deallocate(sedgelx,sedgerx)
    deallocate(Ip,Im)

  end subroutine make_edge_scal_1d
  
  subroutine make_edge_scal_2d(s,ng_s,sedgex,sedgey,ng_se,umac,vmac,ng_um, &
                               force,ng_f,lo,hi,dx,dt,is_vel,adv_bc, &
                               comp,bccomp,is_conservative)

    use bc_module
    use slope_module
    use bl_constants_module
    use variables, only: rel_eps
    use ppm_module
    use probin_module, only: ppm_type, ppm_trace_forces

    integer        , intent(in   ) :: lo(:),hi(:),ng_s,ng_se,ng_um,ng_f
    real(kind=dp_t), intent(in   ) ::      s(lo(1)-ng_s :,lo(2)-ng_s :,:)
    real(kind=dp_t), intent(inout) :: sedgex(lo(1)-ng_se:,lo(2)-ng_se:,:)
    real(kind=dp_t), intent(inout) :: sedgey(lo(1)-ng_se:,lo(2)-ng_se:,:)
    real(kind=dp_t), intent(in   ) ::   umac(lo(1)-ng_um:,lo(2)-ng_um:)
    real(kind=dp_t), intent(in   ) ::   vmac(lo(1)-ng_um:,lo(2)-ng_um:)
    real(kind=dp_t), intent(in   ) ::  force(lo(1)-ng_f :,lo(2)-ng_f :,:)
    real(kind=dp_t), intent(in   ) :: dx(:),dt
    logical        , intent(in   ) :: is_vel
    integer        , intent(in   ) :: adv_bc(:,:,:)
    integer        , intent(in   ) :: comp,bccomp
    logical        , intent(in   ) :: is_conservative

    ! Local variables
    real(kind=dp_t) :: slopex(lo(1)-1:hi(1)+1,lo(2)-1:hi(2)+1,1)
    real(kind=dp_t) :: slopey(lo(1)-1:hi(1)+1,lo(2)-1:hi(2)+1,1)

    real(kind=dp_t) :: hx,hy,dt2,dt4,savg,fl,fr

    integer :: i,j,is,js,ie,je

    real(kind=dp_t), allocatable :: Ip(:,:,:), Ipf(:,:,:)
    real(kind=dp_t), allocatable :: Im(:,:,:), Imf(:,:,:)

    ! these correspond to s_L^x, etc.
    real(kind=dp_t), allocatable:: slx(:,:),srx(:,:)
    real(kind=dp_t), allocatable:: sly(:,:),sry(:,:)

    ! these correspond to s_{\i-\half\e_x}^x, etc.
    real(kind=dp_t), allocatable:: simhx(:,:),simhy(:,:)

    ! these correspond to \mathrm{sedge}_L^x, etc.
    real(kind=dp_t), allocatable:: sedgelx(:,:),sedgerx(:,:)
    real(kind=dp_t), allocatable:: sedgely(:,:),sedgery(:,:)

    allocate(Ip(lo(1)-1:hi(1)+1,lo(2)-1:hi(2)+1,2))
    allocate(Im(lo(1)-1:hi(1)+1,lo(2)-1:hi(2)+1,2))

    allocate(Ipf(lo(1)-1:hi(1)+1,lo(2)-1:hi(2)+1,2))
    allocate(Imf(lo(1)-1:hi(1)+1,lo(2)-1:hi(2)+1,2))

    ! Normal predictor states.
    ! Allocated from lo:hi+1 in the normal direction
    ! lo-1:hi+1 in the transverse direction
    allocate(slx  (lo(1):hi(1)+1,lo(2)-1:hi(2)+1))
    allocate(srx  (lo(1):hi(1)+1,lo(2)-1:hi(2)+1))
    allocate(simhx(lo(1):hi(1)+1,lo(2)-1:hi(2)+1))

    allocate(sly  (lo(1)-1:hi(1)+1,lo(2):hi(2)+1))
    allocate(sry  (lo(1)-1:hi(1)+1,lo(2):hi(2)+1))
    allocate(simhy(lo(1)-1:hi(1)+1,lo(2):hi(2)+1))

    ! Final edge states.
    ! lo:hi+1 in the normal direction
    ! lo:hi in the transverse direction
    allocate(sedgelx(lo(1):hi(1)+1,lo(2):hi(2)))
    allocate(sedgerx(lo(1):hi(1)+1,lo(2):hi(2)))
    allocate(sedgely(lo(1):hi(1),lo(2):hi(2)+1))
    allocate(sedgery(lo(1):hi(1),lo(2):hi(2)+1))

    is = lo(1)
    ie = hi(1)
    js = lo(2)
    je = hi(2)

    if (ppm_type .eq. 0) then
       call slopex_2d(s(:,:,comp:),slopex,lo,hi,ng_s,1,adv_bc(:,:,bccomp:))
       call slopey_2d(s(:,:,comp:),slopey,lo,hi,ng_s,1,adv_bc(:,:,bccomp:))
    else if (ppm_type .eq. 1 .or. ppm_type .eq. 2) then
       call ppm_2d(s(:,:,comp),ng_s, &
                   umac,vmac,ng_um, &
                   Ip,Im,lo,hi,adv_bc(:,:,bccomp),dx,dt,.true.)
       if (ppm_trace_forces == 1) then
          call ppm_2d(force(:,:,comp),ng_s, &
                      umac,vmac,ng_um, &
                      Ipf,Imf,lo,hi,adv_bc(:,:,bccomp),dx,dt,.true.)
       endif
    end if

    dt2 = HALF*dt
    dt4 = dt/4.0d0

    hx = dx(1)
    hy = dx(2)
    
    !******************************************************************
    ! Create s_{\i-\half\e_x}^x, etc.
    !******************************************************************

    ! loop over appropriate x-faces
    if (ppm_type .eq. 0) then
       do j=js-1,je+1
          do i=is,ie+1
             ! make slx, srx with 1D extrapolation
             slx(i,j) = s(i-1,j,comp) + (HALF - dt2*umac(i,j)/hx)*slopex(i-1,j,1)
             srx(i,j) = s(i  ,j,comp) - (HALF + dt2*umac(i,j)/hx)*slopex(i  ,j,1)
          enddo
       enddo       
    else if (ppm_type .eq. 1 .or. ppm_type .eq. 2) then
       do j=js-1,je+1
          do i=is,ie+1
             ! make slx, srx with 1D extrapolation
             slx(i,j) = Ip(i-1,j,1)
             srx(i,j) = Im(i  ,j,1)
          end do
       end do
    end if

    ! impose lo side bc's
    if (adv_bc(1,1,bccomp) .eq. EXT_DIR) then
       slx(is,js-1:je+1) = s(is-1,js-1:je+1,comp)
       srx(is,js-1:je+1) = s(is-1,js-1:je+1,comp)
    else if (adv_bc(1,1,bccomp) .eq. FOEXTRAP .or. &
             adv_bc(1,1,bccomp) .eq. HOEXTRAP) then
       if (is_vel .and. comp .eq. 1) then
          srx(is,js-1:je+1) = min(srx(is,js-1:je+1),ZERO)
       end if
       slx(is,js-1:je+1) = srx(is,js-1:je+1)
    else if (adv_bc(1,1,bccomp) .eq. REFLECT_EVEN) then
       slx(is,js-1:je+1) = srx(is,js-1:je+1)
    else if (adv_bc(1,1,bccomp) .eq. REFLECT_ODD) then
       slx(ie+1,js-1:je+1) = ZERO
       srx(ie+1,js-1:je+1) = ZERO
    else if (adv_bc(1,1,bccomp) .eq. INTERIOR) then
    else
       call bl_error("make_edge_scal_2d: invalid boundary type adv_bc(1,1)")
    end if

    ! impose hi side bc's
    if (adv_bc(1,2,bccomp) .eq. EXT_DIR) then
       slx(ie+1,js-1:je+1) = s(ie+1,js-1:je+1,comp)
       srx(ie+1,js-1:je+1) = s(ie+1,js-1:je+1,comp)
    else if (adv_bc(1,2,bccomp) .eq. FOEXTRAP .or. &
             adv_bc(1,2,bccomp) .eq. HOEXTRAP) then
       if (is_vel .and. comp .eq. 1) then
          slx(ie+1,js-1:je+1) = max(slx(ie+1,js-1:je+1),ZERO)
       end if
       srx(ie+1,js-1:je+1) = slx(ie+1,js-1:je+1)
    else if (adv_bc(1,2,bccomp) .eq. REFLECT_EVEN) then
       srx(ie+1,js-1:je+1) = slx(ie+1,js-1:je+1)
    else if (adv_bc(1,2,bccomp) .eq. REFLECT_ODD) then
       slx(ie+1,js-1:je+1) = ZERO
       srx(ie+1,js-1:je+1) = ZERO
    else if (adv_bc(1,2,bccomp) .eq. INTERIOR) then
    else
       call bl_error("make_edge_scal_2d: invalid boundary type adv_bc(1,2)")
    end if

    do j=js-1,je+1
       do i=is,ie+1
          ! make simhx by solving Riemann problem
          simhx(i,j) = merge(slx(i,j),srx(i,j),umac(i,j) .gt. ZERO)
          savg = HALF*(slx(i,j)+srx(i,j))
          simhx(i,j) = merge(simhx(i,j),savg,abs(umac(i,j)) .gt. rel_eps)
       enddo
    enddo

    ! loop over appropriate y-faces
    if (ppm_type .eq. 0) then
       do j=js,je+1
          do i=is-1,ie+1
             ! make sly, sry with 1D extrapolation
             sly(i,j) = s(i,j-1,comp) + (HALF - dt2*vmac(i,j)/hy)*slopey(i,j-1,1)
             sry(i,j) = s(i,j  ,comp) - (HALF + dt2*vmac(i,j)/hy)*slopey(i,j  ,1)
          enddo
       enddo
    else if (ppm_type .eq. 1 .or. ppm_type .eq. 2) then
       do j=js,je+1
          do i=is-1,ie+1
             ! make sly, sry with 1D extrapolation
             sly(i,j) = Ip(i,j-1,2)
             sry(i,j) = Im(i,j  ,2)
          enddo
       enddo
    end if

    ! impose lo side bc's
    if (adv_bc(2,1,bccomp) .eq. EXT_DIR) then
       sly(is-1:ie+1,js) = s(is-1:ie+1,js-1,comp)
       sry(is-1:ie+1,js) = s(is-1:ie+1,js-1,comp)
    else if (adv_bc(2,1,bccomp) .eq. FOEXTRAP .or. &
             adv_bc(2,1,bccomp) .eq. HOEXTRAP) then
       if (is_vel .and. comp .eq. 2) then
          sry(is-1:ie+1,js) = min(sry(is-1:ie+1,js),ZERO)
       end if
       sly(is-1:ie+1,js) = sry(is-1:ie+1,js)
    else if (adv_bc(2,1,bccomp) .eq. REFLECT_EVEN) then
       sly(is-1:ie+1,js) = sry(is-1:ie+1,js)
    else if (adv_bc(2,1,bccomp) .eq. REFLECT_ODD) then
       sly(is-1:ie+1,js) = ZERO
       sry(is-1:ie+1,js) = ZERO
    else if (adv_bc(2,1,bccomp) .eq. INTERIOR) then
    else
       call bl_error("make_edge_scal_2d: invalid boundary type adv_bc(2,1)")
    end if

    ! impose hi side bc's
    if (adv_bc(2,2,bccomp) .eq. EXT_DIR) then
       sly(is-1:ie+1,je+1) = s(is-1:ie+1,je+1,comp)
       sry(is-1:ie+1,je+1) = s(is-1:ie+1,je+1,comp)
    else if (adv_bc(2,2,bccomp) .eq. FOEXTRAP .or. &
             adv_bc(2,2,bccomp) .eq. HOEXTRAP) then
       if (is_vel .and. comp .eq. 2) then
          sly(is-1:ie+1,je+1) = max(sly(is-1:ie+1,je+1),ZERO)
       end if
       sry(is-1:ie+1,je+1) = sly(is-1:ie+1,je+1)
    else if (adv_bc(2,2,bccomp) .eq. REFLECT_EVEN) then
       sry(is-1:ie+1,je+1) = sly(is-1:ie+1,je+1)
    else if (adv_bc(2,2,bccomp) .eq. REFLECT_ODD) then
       sly(is-1:ie+1,je+1) = ZERO
       sry(is-1:ie+1,je+1) = ZERO
    else if (adv_bc(2,2,bccomp) .eq. INTERIOR) then
    else
       call bl_error("make_edge_scal_2d: invalid boundary type adv_bc(2,2)")
    end if

    do j=js,je+1
       do i=is-1,ie+1
          ! make simhy by solving Riemann problem
          simhy(i,j) = merge(sly(i,j),sry(i,j),vmac(i,j) .gt. ZERO)
          savg = HALF*(sly(i,j)+sry(i,j))
          simhy(i,j) = merge(simhy(i,j),savg,abs(vmac(i,j)) .gt. rel_eps)
       enddo
    enddo

    !******************************************************************
    ! Create sedgelx, etc.
    !******************************************************************

    ! loop over appropriate x-faces
    do j=js,je
       do i=is,ie+1
          ! make sedgelx, sedgerx
          fl = merge(force(i-1,j,comp), Ipf(i-1,j,1), ppm_trace_forces == 0)
          fr = merge(force(i,j  ,comp), Imf(i,  j,1), ppm_trace_forces == 0)

          if(is_conservative) then
             sedgelx(i,j) = slx(i,j) &
                  - (dt2/hy)*(simhy(i-1,j+1)*vmac(i-1,j+1) - simhy(i-1,j)*vmac(i-1,j)) &
                  - (dt2/hx)*s(i-1,j,comp)*(umac(i  ,j)-umac(i-1,j)) &
                  + dt2*fl
             sedgerx(i,j) = srx(i,j) &
                  - (dt2/hy)*(simhy(i  ,j+1)*vmac(i  ,j+1) - simhy(i  ,j)*vmac(i  ,j)) &
                  - (dt2/hx)*s(i  ,j,comp)*(umac(i+1,j)-umac(i  ,j)) &
                  + dt2*fr
          else
             sedgelx(i,j) = slx(i,j) &
                  - (dt4/hy)*(vmac(i-1,j+1)+vmac(i-1,j))*(simhy(i-1,j+1)-simhy(i-1,j)) &
                  + dt2*fl
             sedgerx(i,j) = srx(i,j) &
                  - (dt4/hy)*(vmac(i  ,j+1)+vmac(i  ,j))*(simhy(i  ,j+1)-simhy(i  ,j)) &
                  + dt2*fr
          end if

          ! make sedgex by solving Riemann problem
          ! boundary conditions enforced outside of i,j loop
          sedgex(i,j,comp) = merge(sedgelx(i,j),sedgerx(i,j),umac(i,j) .gt. ZERO)
          savg = HALF*(sedgelx(i,j)+sedgerx(i,j))
          sedgex(i,j,comp) = merge(sedgex(i,j,comp),savg,abs(umac(i,j)) .gt. rel_eps)
       enddo
    enddo
 
    ! impose lo side bc's
    if (adv_bc(1,1,bccomp) .eq. EXT_DIR) then
       sedgex(is,js:je,comp) = s(is-1,js:je,comp)
    else if (adv_bc(1,1,bccomp) .eq. FOEXTRAP .or. &
             adv_bc(1,1,bccomp) .eq. HOEXTRAP) then
       if (is_vel .and. comp .eq. 1) then
          sedgex(is,js:je,comp) = min(sedgerx(is,js:je),ZERO)
       else
          sedgex(is,js:je,comp) = sedgerx(is,js:je)
       end if
    else if (adv_bc(1,1,bccomp) .eq. REFLECT_EVEN) then
       sedgex(is,js:je,comp) = sedgerx(is,js:je)
    else if (adv_bc(1,1,bccomp) .eq. REFLECT_ODD) then
       sedgex(is,js:je,comp) = ZERO
    else if (adv_bc(1,1,bccomp) .eq. INTERIOR) then
    else
       call bl_error("make_edge_scal_2d: invalid boundary type adv_bc(1,1)")
    end if

    ! impose hi side bc's
    if (adv_bc(1,2,bccomp) .eq. EXT_DIR) then
       sedgex(ie+1,js:je,comp) = s(ie+1,js:je,comp)
    else if (adv_bc(1,2,bccomp) .eq. FOEXTRAP .or. &
             adv_bc(1,2,bccomp) .eq. HOEXTRAP) then
       if (is_vel .and. comp .eq. 1) then
          sedgex(ie+1,js:je,comp) = max(sedgelx(ie+1,js:je),ZERO)
       else
          sedgex(ie+1,js:je,comp) = sedgelx(ie+1,js:je)
       end if
    else if (adv_bc(1,2,bccomp) .eq. REFLECT_EVEN) then
       sedgex(ie+1,js:je,comp) = sedgelx(ie+1,js:je)
    else if (adv_bc(1,2,bccomp) .eq. REFLECT_ODD) then
       sedgex(ie+1,js:je,comp) = ZERO
    else if (adv_bc(1,2,bccomp) .eq. INTERIOR) then
    else
       call bl_error("make_edge_scal_2d: invalid boundary type adv_bc(1,2)")
    end if

    ! loop over appropriate y-faces
    do j=js,je+1
       do i=is,ie
          ! make sedgely, sedgery
          fl = merge(force(i,j-1,comp), Ipf(i,j-1,2), ppm_trace_forces == 0)
          fr = merge(force(i,j  ,comp), Imf(i,j  ,2), ppm_trace_forces == 0)

          if(is_conservative) then
             sedgely(i,j) = sly(i,j) &
                  - (dt2/hx)*(simhx(i+1,j-1)*umac(i+1,j-1) - simhx(i,j-1)*umac(i,j-1)) &
                  - (dt2/hy)*s(i,j-1,comp)*(vmac(i,j  )-vmac(i,j-1)) &
                  + dt2*fl
             sedgery(i,j) = sry(i,j) &
                  - (dt2/hx)*(simhx(i+1,j  )*umac(i+1,j  ) - simhx(i,j  )*umac(i,j  )) &
                  - (dt2/hy)*s(i,j  ,comp)*(vmac(i,j+1)-vmac(i,j  )) &
                  + dt2*fr
          else
             sedgely(i,j) = sly(i,j) &
                  - (dt4/hx)*(umac(i+1,j-1)+umac(i,j-1))*(simhx(i+1,j-1)-simhx(i,j-1)) &
                  + dt2*fl
             sedgery(i,j) = sry(i,j) &
                  - (dt4/hx)*(umac(i+1,j  )+umac(i,j  ))*(simhx(i+1,j  )-simhx(i,j  )) &
                  + dt2*fr
          end if

          ! make sedgey by solving Riemann problem
          ! boundary conditions enforced outside of i,j loop
          sedgey(i,j,comp) = merge(sedgely(i,j),sedgery(i,j),vmac(i,j) .gt. ZERO)
          savg = HALF*(sedgely(i,j)+sedgery(i,j))
          sedgey(i,j,comp) = merge(sedgey(i,j,comp),savg,abs(vmac(i,j)) .gt. rel_eps)
       enddo
    enddo

    ! impose lo side bc's
    if (adv_bc(2,1,bccomp) .eq. EXT_DIR) then
       sedgey(is:ie,js,comp) = s(is:ie,js-1,comp)
    else if (adv_bc(2,1,bccomp) .eq. FOEXTRAP .or. &
             adv_bc(2,1,bccomp) .eq. HOEXTRAP) then
       if (is_vel .and. comp .eq. 2) then
          sedgey(is:ie,js,comp) = min(sedgery(is:ie,js),ZERO)
       else
          sedgey(is:ie,js,comp) = sedgery(is:ie,js)
       end if
    else if (adv_bc(2,1,bccomp) .eq. REFLECT_EVEN) then
       sedgey(is:ie,js,comp) = sedgery(is:ie,js)
    else if (adv_bc(2,1,bccomp) .eq. REFLECT_ODD) then
       sedgey(is:ie,js,comp) = ZERO
    else if (adv_bc(2,1,bccomp) .eq. INTERIOR) then
    else
       call bl_error("make_edge_scal_2d: invalid boundary type adv_bc(2,1)")
    end if

    ! impose hi side bc's
    if (adv_bc(2,2,bccomp) .eq. EXT_DIR) then
       sedgey(is:ie,je+1,comp) = s(is:ie,je+1,comp)
    else if (adv_bc(2,2,bccomp) .eq. FOEXTRAP .or. &
             adv_bc(2,2,bccomp) .eq. HOEXTRAP) then
       if (is_vel .and. comp .eq. 2) then
          sedgey(is:ie,je+1,comp) = max(sedgely(is:ie,je+1),ZERO)
       else
          sedgey(is:ie,je+1,comp) = sedgely(is:ie,je+1)
       end if
    else if (adv_bc(2,2,bccomp) .eq. REFLECT_EVEN) then
          sedgey(is:ie,je+1,comp) = sedgely(is:ie,je+1)
    else if (adv_bc(2,2,bccomp) .eq. REFLECT_ODD) then
       sedgey(is:ie,je+1,comp) = ZERO
    else if (adv_bc(2,2,bccomp) .eq. INTERIOR) then
    else
       call bl_error("make_edge_scal_2d: invalid boundary type adv_bc(2,2)")
    end if

    deallocate(slx,srx,sly,sry,simhx,simhy,sedgelx,sedgerx,sedgely,sedgery)
    deallocate(Ip,Im)

  end subroutine make_edge_scal_2d

  subroutine make_edge_scal_3d(s,ng_s,sedgex,sedgey,sedgez,ng_se,umac,vmac,wmac,ng_um, &
                               force,ng_f,lo,hi,dx,dt,is_vel,adv_bc,comp,bccomp, &
                               is_conservative)

    use bc_module
    use slope_module
    use bl_constants_module
    use variables, only: rel_eps
    use ppm_module
    use probin_module, only: ppm_type, ppm_trace_forces

    integer        , intent(in   ) :: lo(:),hi(:),ng_s,ng_se,ng_um,ng_f
    real(kind=dp_t), intent(in   ) ::      s(lo(1)-ng_s :,lo(2)-ng_s :,lo(3)-ng_s :,:)
    real(kind=dp_t), intent(inout) :: sedgex(lo(1)-ng_se:,lo(2)-ng_se:,lo(3)-ng_se:,:)
    real(kind=dp_t), intent(inout) :: sedgey(lo(1)-ng_se:,lo(2)-ng_se:,lo(3)-ng_se:,:)
    real(kind=dp_t), intent(inout) :: sedgez(lo(1)-ng_se:,lo(2)-ng_se:,lo(3)-ng_se:,:)
    real(kind=dp_t), intent(in   ) ::   umac(lo(1)-ng_um:,lo(2)-ng_um:,lo(3)-ng_um:)
    real(kind=dp_t), intent(in   ) ::   vmac(lo(1)-ng_um:,lo(2)-ng_um:,lo(3)-ng_um:)
    real(kind=dp_t), intent(in   ) ::   wmac(lo(1)-ng_um:,lo(2)-ng_um:,lo(3)-ng_um:)
    real(kind=dp_t), intent(in   ) ::  force(lo(1)-ng_f :,lo(2)-ng_f :,lo(3)-ng_f :,:)
    real(kind=dp_t), intent(in   ) :: dx(:),dt
    logical        , intent(in   ) :: is_vel
    integer        , intent(in   ) :: adv_bc(:,:,:)
    integer        , intent(in   ) :: comp,bccomp
    logical        , intent(in   ) :: is_conservative

    ! Local variables
    real(kind=dp_t), allocatable :: slopex(:,:,:,:)
    real(kind=dp_t), allocatable :: slopey(:,:,:,:)
    real(kind=dp_t), allocatable :: slopez(:,:,:,:)

    real(kind=dp_t) :: hx,hy,hz,dt2,dt3,dt4,dt6,fl,fr
    real(kind=dp_t) :: savg

    integer :: i,j,k,is,js,ks,ie,je,ke

    real(kind=dp_t), allocatable :: Ip(:,:,:,:), Ipf(:,:,:,:)
    real(kind=dp_t), allocatable :: Im(:,:,:,:), Imf(:,:,:,:)

    ! these correspond to s_L^x, etc.
    real(kind=dp_t), allocatable:: slx(:,:,:),srx(:,:,:)
    real(kind=dp_t), allocatable:: sly(:,:,:),sry(:,:,:)
    real(kind=dp_t), allocatable:: slz(:,:,:),srz(:,:,:)

    ! these correspond to s_{\i-\half\e_x}^x, etc.
    real(kind=dp_t), allocatable:: simhx(:,:,:),simhy(:,:,:),simhz(:,:,:)

    ! these correspond to s_L^{x|y}, etc.
    real(kind=dp_t), allocatable:: slxy(:,:,:),srxy(:,:,:),slxz(:,:,:),srxz(:,:,:)
    real(kind=dp_t), allocatable:: slyx(:,:,:),sryx(:,:,:),slyz(:,:,:),sryz(:,:,:)
    real(kind=dp_t), allocatable:: slzx(:,:,:),srzx(:,:,:),slzy(:,:,:),srzy(:,:,:)

    ! these correspond to s_{\i-\half\e_x}^{x|y}, etc.
    real(kind=dp_t), allocatable:: simhxy(:,:,:),simhxz(:,:,:)
    real(kind=dp_t), allocatable:: simhyx(:,:,:),simhyz(:,:,:)
    real(kind=dp_t), allocatable:: simhzx(:,:,:),simhzy(:,:,:)

    ! these correspond to \mathrm{sedge}_L^x, etc.
    real(kind=dp_t), allocatable:: sedgelx(:,:,:),sedgerx(:,:,:)
    real(kind=dp_t), allocatable:: sedgely(:,:,:),sedgery(:,:,:)
    real(kind=dp_t), allocatable:: sedgelz(:,:,:),sedgerz(:,:,:)

    allocate(slopex(lo(1)-1:hi(1)+1,lo(2)-1:hi(2)+1,lo(3)-1:hi(3)+1,1))
    allocate(slopey(lo(1)-1:hi(1)+1,lo(2)-1:hi(2)+1,lo(3)-1:hi(3)+1,1))
    allocate(slopez(lo(1)-1:hi(1)+1,lo(2)-1:hi(2)+1,lo(3)-1:hi(3)+1,1))

    allocate(Ip(lo(1)-1:hi(1)+1,lo(2)-1:hi(2)+1,lo(3)-1:hi(3)+1,3))
    allocate(Im(lo(1)-1:hi(1)+1,lo(2)-1:hi(2)+1,lo(3)-1:hi(3)+1,3))

    allocate(Ipf(lo(1)-1:hi(1)+1,lo(2)-1:hi(2)+1,lo(3)-1:hi(3)+1,3))
    allocate(Imf(lo(1)-1:hi(1)+1,lo(2)-1:hi(2)+1,lo(3)-1:hi(3)+1,3))

    is = lo(1)
    ie = hi(1)
    js = lo(2)
    je = hi(2)
    ks = lo(3)
    ke = hi(3)

    if (ppm_type .eq. 0) then
       do k = lo(3)-1,hi(3)+1
          call slopex_2d(s(:,:,k,comp:),slopex(:,:,k,:),lo,hi,ng_s,1,adv_bc(:,:,bccomp:))
          call slopey_2d(s(:,:,k,comp:),slopey(:,:,k,:),lo,hi,ng_s,1,adv_bc(:,:,bccomp:))
       end do
       call slopez_3d(s(:,:,:,comp:),slopez,lo,hi,ng_s,1,adv_bc(:,:,bccomp:))
    else if (ppm_type .eq. 1 .or. ppm_type .eq. 2) then
       call ppm_3d(s(:,:,:,comp),ng_s,umac,vmac,wmac,ng_um,Ip,Im, &
                   lo,hi,adv_bc(:,:,bccomp),dx,dt,.true.)
       if (ppm_trace_forces == 1) then
          call ppm_3d(force(:,:,:,comp),ng_s,umac,vmac,wmac,ng_um,Ipf,Imf, &
                      lo,hi,adv_bc(:,:,bccomp),dx,dt,.true.)
       endif
    end if

    dt2 = HALF*dt
    dt3 = dt/3.0d0
    dt4 = dt/4.0d0
    dt6 = dt/6.0d0
    
    hx = dx(1)
    hy = dx(2)
    hz = dx(3)

    !******************************************************************
    ! Create s_{\i-\half\e_x}^x, etc.
    !******************************************************************

    ! Normal predictor states.
    ! Allocated from lo:hi+1 in the normal direction
    ! lo-1:hi+1 in the transverse directions
    allocate(slx  (lo(1):hi(1)+1,lo(2)-1:hi(2)+1,lo(3)-1:hi(3)+1))
    allocate(srx  (lo(1):hi(1)+1,lo(2)-1:hi(2)+1,lo(3)-1:hi(3)+1))
    allocate(simhx(lo(1):hi(1)+1,lo(2)-1:hi(2)+1,lo(3)-1:hi(3)+1))
    
    ! loop over appropriate x-faces
    if (ppm_type .eq. 0) then
       !$OMP PARALLEL DO PRIVATE(i,j,k)
       do k=ks-1,ke+1
          do j=js-1,je+1
             do i=is,ie+1
                ! make slx, srx with 1D extrapolation
                slx(i,j,k) = s(i-1,j,k,comp) + (HALF - dt2*umac(i,j,k)/hx)*slopex(i-1,j,k,1)
                srx(i,j,k) = s(i  ,j,k,comp) - (HALF + dt2*umac(i,j,k)/hx)*slopex(i  ,j,k,1)
             enddo
          enddo
       enddo
       !$OMP END PARALLEL DO
    else if (ppm_type .eq. 1 .or. ppm_type .eq. 2) then
       do k=ks-1,ke+1
          do j=js-1,je+1
             do i=is,ie+1
                ! make slx, srx with 1D extrapolation
                slx(i,j,k) = Ip(i-1,j,k,1)
                srx(i,j,k) = Im(i  ,j,k,1)
             end do
          end do
       end do
    end if

    ! impose lo side bc's
    if (adv_bc(1,1,bccomp) .eq. EXT_DIR) then
       slx(is,js-1:je+1,ks-1:ke+1) = s(is-1,js-1:je+1,ks-1:ke+1,comp)
       srx(is,js-1:je+1,ks-1:ke+1) = s(is-1,js-1:je+1,ks-1:ke+1,comp)
    else if (adv_bc(1,1,bccomp) .eq. FOEXTRAP .or. &
             adv_bc(1,1,bccomp) .eq. HOEXTRAP) then
       if (is_vel .and. comp .eq. 1) then
          srx(is,js-1:je+1,ks-1:ke+1) = min(srx(is,js-1:je+1,ks-1:ke+1),ZERO)
       end if
       slx(is,js-1:je+1,ks-1:ke+1) = srx(is,js-1:je+1,ks-1:ke+1)
    else if (adv_bc(1,1,bccomp) .eq. REFLECT_EVEN) then
       slx(is,js-1:je+1,ks-1:ke+1) = srx(is,js-1:je+1,ks-1:ke+1)
    else if (adv_bc(1,1,bccomp) .eq. REFLECT_ODD) then
       slx(is,js-1:je+1,ks-1:ke+1) = ZERO
       srx(is,js-1:je+1,ks-1:ke+1) = ZERO
    else if (adv_bc(1,1,bccomp) .eq. INTERIOR) then
    else
       call bl_error("make_edge_scal_3d: invalid boundary type adv_bc(1,1)")
    end if

    ! impose hi side bc's
    if (adv_bc(1,2,bccomp) .eq. EXT_DIR) then
       slx(ie+1,js-1:je+1,ks-1:ke+1) = s(ie+1,js-1:je+1,ks-1:ke+1,comp)
       srx(ie+1,js-1:je+1,ks-1:ke+1) = s(ie+1,js-1:je+1,ks-1:ke+1,comp)
    else if (adv_bc(1,2,bccomp) .eq. FOEXTRAP .or. &
             adv_bc(1,2,bccomp) .eq. HOEXTRAP) then
       if (is_vel .and. comp .eq. 1) then
          slx(ie+1,js-1:je+1,ks-1:ke+1) = max(slx(ie+1,js-1:je+1,ks-1:ke+1),ZERO)
       end if
       srx(ie+1,js-1:je+1,ks-1:ke+1) = slx(ie+1,js-1:je+1,ks-1:ke+1)
    else if (adv_bc(1,2,bccomp) .eq. REFLECT_EVEN) then
       srx(ie+1,js-1:je+1,ks-1:ke+1) = slx(ie+1,js-1:je+1,ks-1:ke+1)
    else if (adv_bc(1,2,bccomp) .eq. REFLECT_ODD) then
          slx(ie+1,js-1:je+1,ks-1:ke+1) = ZERO
          srx(ie+1,js-1:je+1,ks-1:ke+1) = ZERO
    else if (adv_bc(1,2,bccomp) .eq. INTERIOR) then
    else
       call bl_error("make_edge_scal_3d: invalid boundary type adv_bc(1,2)")
    end if

    !$OMP PARALLEL DO PRIVATE(i,j,k,savg)
    do k=ks-1,ke+1
       do j=js-1,je+1
          do i=is,ie+1
             ! make simhx by solving Riemann problem
             simhx(i,j,k) = merge(slx(i,j,k),srx(i,j,k),umac(i,j,k) .gt. ZERO)
             savg = HALF*(slx(i,j,k)+srx(i,j,k))
             simhx(i,j,k) = merge(simhx(i,j,k),savg,abs(umac(i,j,k)) .gt. rel_eps)
          enddo
       enddo
    enddo
    !$OMP END PARALLEL DO

    ! Normal predictor states.
    ! Allocated from lo:hi+1 in the normal direction
    ! lo-1:hi+1 in the transverse directions
    allocate(sly  (lo(1)-1:hi(1)+1,lo(2):hi(2)+1,lo(3)-1:hi(3)+1))
    allocate(sry  (lo(1)-1:hi(1)+1,lo(2):hi(2)+1,lo(3)-1:hi(3)+1))
    allocate(simhy(lo(1)-1:hi(1)+1,lo(2):hi(2)+1,lo(3)-1:hi(3)+1))

    ! loop over appropriate y-faces
    if (ppm_type .eq. 0) then
       !$OMP PARALLEL DO PRIVATE(i,j,k)
       do k=ks-1,ke+1
          do j=js,je+1
             do i=is-1,ie+1
                ! make sly, sry with 1D extrapolation
                sly(i,j,k) = s(i,j-1,k,comp) + (HALF - dt2*vmac(i,j,k)/hy)*slopey(i,j-1,k,1)
                sry(i,j,k) = s(i,j  ,k,comp) - (HALF + dt2*vmac(i,j,k)/hy)*slopey(i,j  ,k,1)
             enddo
          enddo
       enddo
       !$OMP END PARALLEL DO
    else if (ppm_type .eq. 1 .or. ppm_type .eq. 2) then
       do k=ks-1,ke+1
          do j=js,je+1
             do i=is-1,ie+1
                ! make sly, sry with 1D extrapolation
                sly(i,j,k) = Ip(i,j-1,k,2)
                sry(i,j,k) = Im(i,j  ,k,2)
             enddo
          enddo
       enddo
    end if

    ! impose lo side bc's
    if (adv_bc(2,1,bccomp) .eq. EXT_DIR) then
       sly(is-1:ie+1,js,ks-1:ke+1) = s(is-1:ie+1,js-1,ks-1:ke+1,comp)
       sry(is-1:ie+1,js,ks-1:ke+1) = s(is-1:ie+1,js-1,ks-1:ke+1,comp)
    else if (adv_bc(2,1,bccomp) .eq. FOEXTRAP .or. &
             adv_bc(2,1,bccomp) .eq. HOEXTRAP) then
       if (is_vel .and. comp .eq. 2) then
          sry(is-1:ie+1,js,ks-1:ke+1) = min(sry(is-1:ie+1,js,ks-1:ke+1),ZERO)
       end if
       sly(is-1:ie+1,js,ks-1:ke+1) = sry(is-1:ie+1,js,ks-1:ke+1)
    else if (adv_bc(2,1,bccomp) .eq. REFLECT_EVEN) then
       sly(is-1:ie+1,js,ks-1:ke+1) = sry(is-1:ie+1,js,ks-1:ke+1)
    else if (adv_bc(2,1,bccomp) .eq. REFLECT_ODD) then
       sly(is-1:ie+1,js,ks-1:ke+1) = ZERO
       sry(is-1:ie+1,js,ks-1:ke+1) = ZERO
    else if (adv_bc(2,1,bccomp) .eq. INTERIOR) then
    else
       call bl_error("make_edge_scal_3d: invalid boundary type adv_bc(2,1)")
    end if

    ! impose hi side bc's
    if (adv_bc(2,2,bccomp) .eq. EXT_DIR) then
       sly(is-1:ie+1,je+1,ks-1:ke+1) = s(is-1:ie+1,je+1,ks-1:ke+1,comp)
       sry(is-1:ie+1,je+1,ks-1:ke+1) = s(is-1:ie+1,je+1,ks-1:ke+1,comp)
    else if (adv_bc(2,2,bccomp) .eq. FOEXTRAP .or. &
             adv_bc(2,2,bccomp) .eq. HOEXTRAP) then
       if (is_vel .and. comp .eq. 2) then
          sly(is-1:ie+1,je+1,ks-1:ke+1) = max(sly(is-1:ie+1,je+1,ks-1:ke+1),ZERO)
       end if
       sry(is-1:ie+1,je+1,ks-1:ke+1) = sly(is-1:ie+1,je+1,ks-1:ke+1)
    else if (adv_bc(2,2,bccomp) .eq. REFLECT_EVEN) then
       sry(is-1:ie+1,je+1,ks-1:ke+1) = sly(is-1:ie+1,je+1,ks-1:ke+1)
    else if (adv_bc(2,2,bccomp) .eq. REFLECT_ODD) then
       sly(is-1:ie+1,je+1,ks-1:ke+1) = ZERO
       sry(is-1:ie+1,je+1,ks-1:ke+1) = ZERO
    else if (adv_bc(2,2,bccomp) .eq. INTERIOR) then
    else
       call bl_error("make_edge_scal_3d: invalid boundary type adv_bc(2,2)")
    end if

    !$OMP PARALLEL DO PRIVATE(i,j,k,savg)
    do k=ks-1,ke+1
       do j=js,je+1
          do i=is-1,ie+1
             ! make simhy by solving Riemann problem
             simhy(i,j,k) = merge(sly(i,j,k),sry(i,j,k),vmac(i,j,k) .gt. ZERO)
             savg = HALF*(sly(i,j,k)+sry(i,j,k))
             simhy(i,j,k) = merge(simhy(i,j,k),savg,abs(vmac(i,j,k)) .gt. rel_eps)
          enddo
       enddo
    enddo
    !$OMP END PARALLEL DO

    ! Normal predictor states.
    ! Allocated from lo:hi+1 in the normal direction
    ! lo-1:hi+1 in the transverse directions
    allocate(slz  (lo(1)-1:hi(1)+1,lo(2)-1:hi(2)+1,lo(3):hi(3)+1))
    allocate(srz  (lo(1)-1:hi(1)+1,lo(2)-1:hi(2)+1,lo(3):hi(3)+1))
    allocate(simhz(lo(1)-1:hi(1)+1,lo(2)-1:hi(2)+1,lo(3):hi(3)+1))

    ! loop over appropriate z-faces
    if (ppm_type .eq. 0) then
       !$OMP PARALLEL DO PRIVATE(i,j,k)
       do k=ks,ke+1
          do j=js-1,je+1
             do i=is-1,ie+1
                ! make slz, srz with 1D extrapolation
                slz(i,j,k) = s(i,j,k-1,comp) + (HALF - dt2*wmac(i,j,k)/hz)*slopez(i,j,k-1,1)
                srz(i,j,k) = s(i,j,k  ,comp) - (HALF + dt2*wmac(i,j,k)/hz)*slopez(i,j,k  ,1)
             enddo
          enddo
       enddo
       !$OMP END PARALLEL DO
    else if (ppm_type .eq. 1 .or. ppm_type .eq. 2) then
       do k=ks,ke+1
          do j=js-1,je+1
             do i=is-1,ie+1
                ! make slz, srz with 1D extrapolation
                slz(i,j,k) = Ip(i,j,k-1,3)
                srz(i,j,k) = Im(i,j,k  ,3)
             enddo
          enddo
       enddo
    end if

    deallocate(slopex,slopey,slopez,Ip,Im)

    ! impose lo side bc's
    if (adv_bc(3,1,bccomp) .eq. EXT_DIR) then
       slz(is-1:ie+1,js-1:je+1,ks) = s(is-1:ie+1,js-1:je+1,ks,comp)
       srz(is-1:ie+1,js-1:je+1,ks) = s(is-1:ie+1,js-1:je+1,ks,comp)
    else if (adv_bc(3,1,bccomp) .eq. FOEXTRAP .or. &
             adv_bc(3,1,bccomp) .eq. HOEXTRAP) then
       if (is_vel .and. comp .eq. 3) then
          srz(is-1:ie+1,js-1:je+1,ks) = min(srz(is-1:ie+1,js-1:je+1,ks),ZERO)
       end if
       slz(is-1:ie+1,js-1:je+1,ks) = srz(is-1:ie+1,js-1:je+1,ks)
    else if (adv_bc(3,1,bccomp) .eq. REFLECT_EVEN) then
       slz(is-1:ie+1,js-1:je+1,ks) = srz(is-1:ie+1,js-1:je+1,ks)
    else if (adv_bc(3,1,bccomp) .eq. REFLECT_ODD) then
       slz(is-1:ie+1,js-1:je+1,ks) = ZERO
       srz(is-1:ie+1,js-1:je+1,ks) = ZERO
    else if (adv_bc(3,1,bccomp) .eq. INTERIOR) then
    else
       call bl_error("make_edge_scal_3d: invalid boundary type adv_bc(3,1)")
    end if

    ! impose hi side bc's
    if (adv_bc(3,2,bccomp) .eq. EXT_DIR) then
       slz(is-1:ie+1,js-1:je+1,ke+1) = s(is-1:ie+1,js-1:je+1,ke+1,comp)
       srz(is-1:ie+1,js-1:je+1,ke+1) = s(is-1:ie+1,js-1:je+1,ke+1,comp)
    else if (adv_bc(3,2,bccomp) .eq. FOEXTRAP .or. &
             adv_bc(3,2,bccomp) .eq. HOEXTRAP) then
       if (is_vel .and. comp .eq. 3) then
          slz(is-1:ie+1,js-1:je+1,ke+1) = max(slz(is-1:ie+1,js-1:je+1,ke+1),ZERO)
       end if
       srz(is-1:ie+1,js-1:je+1,ke+1) = slz(is-1:ie+1,js-1:je+1,ke+1)
    else if (adv_bc(3,2,bccomp) .eq. REFLECT_EVEN) then
       srz(is-1:ie+1,js-1:je+1,ke+1) = slz(is-1:ie+1,js-1:je+1,ke+1)
    else if (adv_bc(3,2,bccomp) .eq. REFLECT_ODD) then
       slz(is-1:ie+1,js-1:je+1,ke+1) = ZERO
       srz(is-1:ie+1,js-1:je+1,ke+1) = ZERO
    else if (adv_bc(3,2,bccomp) .eq. INTERIOR) then
    else
       call bl_error("make_edge_scal_3d: invalid boundary type adv_bc(3,2)")
    end if

    !$OMP PARALLEL DO PRIVATE(i,j,k,savg)
    do k=ks,ke+1
       do j=js-1,je+1
          do i=is-1,ie+1
             ! make simhz by solving Riemann problem
             simhz(i,j,k) = merge(slz(i,j,k),srz(i,j,k),wmac(i,j,k) .gt. ZERO)
             savg = HALF*(slz(i,j,k)+srz(i,j,k))
             simhz(i,j,k) = merge(simhz(i,j,k),savg,abs(wmac(i,j,k)) .gt. rel_eps)
          enddo
       enddo
    enddo
    !$OMP END PARALLEL DO

    !******************************************************************
    ! Create s_{\i-\half\e_x}^{x|y}, etc.
    !******************************************************************

    allocate(slxy  (lo(1):hi(1)+1,lo(2):hi(2),lo(3)-1:hi(3)+1))
    allocate(srxy  (lo(1):hi(1)+1,lo(2):hi(2),lo(3)-1:hi(3)+1))
    allocate(simhxy(lo(1):hi(1)+1,lo(2):hi(2),lo(3)-1:hi(3)+1))

    ! loop over appropriate xy faces
    if (is_conservative) then
       !$OMP PARALLEL DO PRIVATE(i,j,k)
       do k=ks-1,ke+1
          do j=js,je
             do i=is,ie+1
                ! make slxy, srxy by updating 1D extrapolation
                slxy(i,j,k) = slx(i,j,k) &
                     - (dt3/hy)*(simhy(i-1,j+1,k)*vmac(i-1,j+1,k) &
                     - simhy(i-1,j,k)*vmac(i-1,j,k))
                srxy(i,j,k) = srx(i,j,k) &
                     - (dt3/hy)*(simhy(i  ,j+1,k)*vmac(i  ,j+1,k) &
                     - simhy(i  ,j,k)*vmac(i  ,j,k))
             enddo
          enddo
       enddo
       !$OMP END PARALLEL DO
    else
       !$OMP PARALLEL DO PRIVATE(i,j,k)
       do k=ks-1,ke+1
          do j=js,je
             do i=is,ie+1
                ! make slxy, srxy by updating 1D extrapolation
                slxy(i,j,k) = slx(i,j,k) &
                     - (dt6/hy)*(vmac(i-1,j+1,k)+vmac(i-1,j,k)) &
                     *(simhy(i-1,j+1,k)-simhy(i-1,j,k))
                srxy(i,j,k) = srx(i,j,k) &
                     - (dt6/hy)*(vmac(i  ,j+1,k)+vmac(i  ,j,k)) &
                     *(simhy(i  ,j+1,k)-simhy(i  ,j,k))
             enddo
          enddo
       enddo
       !$OMP END PARALLEL DO
    end if

    ! impose lo side bc's
    if (adv_bc(1,1,bccomp) .eq. EXT_DIR) then
       slxy(is,js:je,ks-1:ke+1) = s(is-1,js:je,ks-1:ke+1,comp)
       srxy(is,js:je,ks-1:ke+1) = s(is-1,js:je,ks-1:ke+1,comp)
    else if (adv_bc(1,1,bccomp) .eq. FOEXTRAP .or. &
             adv_bc(1,1,bccomp) .eq. HOEXTRAP) then
       if (is_vel .and. comp .eq. 1) then
          srxy(is,js:je,ks-1:ke+1) = min(srxy(is,js:je,ks-1:ke+1),ZERO)
       end if
       slxy(is,js:je,ks-1:ke+1) = srxy(is,js:je,ks-1:ke+1)
    else if (adv_bc(1,1,bccomp) .eq. REFLECT_EVEN) then
       slxy(is,js:je,ks-1:ke+1) = srxy(is,js:je,ks-1:ke+1)
    else if (adv_bc(1,1,bccomp) .eq. REFLECT_ODD) then
       slxy(is,js:je,ks-1:ke+1) = ZERO
       srxy(is,js:je,ks-1:ke+1) = ZERO
    else if (adv_bc(1,1,bccomp) .eq. INTERIOR) then
    else
       call bl_error("make_edge_scal_3d: invalid boundary type adv_bc(1,1)")
    end if

    ! impose hi side bc's
    if (adv_bc(1,2,bccomp) .eq. EXT_DIR) then
       slxy(ie+1,js:je,ks-1:ke+1) = s(ie+1,js:je,ks-1:ke+1,comp)
       srxy(ie+1,js:je,ks-1:ke+1) = s(ie+1,js:je,ks-1:ke+1,comp)
    else if (adv_bc(1,2,bccomp) .eq. FOEXTRAP .or. &
             adv_bc(1,2,bccomp) .eq. HOEXTRAP) then
       if (is_vel .and. comp .eq. 1) then
          slxy(ie+1,js:je,ks-1:ke+1) = max(slxy(ie+1,js:je,ks-1:ke+1),ZERO)
       end if
       srxy(ie+1,js:je,ks-1:ke+1) = slxy(ie+1,js:je,ks-1:ke+1)
    else if (adv_bc(1,2,bccomp) .eq. REFLECT_EVEN) then
       srxy(ie+1,js:je,ks-1:ke+1) = slxy(ie+1,js:je,ks-1:ke+1)
    else if (adv_bc(1,2,bccomp) .eq. REFLECT_ODD) then
       slxy(ie+1,js:je,ks-1:ke+1) = ZERO
       srxy(ie+1,js:je,ks-1:ke+1) = ZERO
    else if (adv_bc(1,2,bccomp) .eq. INTERIOR) then
    else
       call bl_error("make_edge_scal_3d: invalid boundary type adv_bc(1,2)")
    end if

    !$OMP PARALLEL DO PRIVATE(i,j,k,savg)
    do k=ks-1,ke+1
       do j=js,je
          do i=is,ie+1
             ! make simhxy by solving Riemann problem
             simhxy(i,j,k) = merge(slxy(i,j,k),srxy(i,j,k),umac(i,j,k) .gt. ZERO)
             savg = HALF*(slxy(i,j,k)+srxy(i,j,k))
             simhxy(i,j,k) = merge(simhxy(i,j,k),savg,abs(umac(i,j,k)) .gt. rel_eps)
          enddo
       enddo
    enddo
    !$OMP END PARALLEL DO

    deallocate(slxy,srxy)

    ! loop over appropriate xz faces

    ! These are transverse terms.  The size allocation is tricky.
    ! lo:hi+1 in normal direction
    ! lo:hi in transverse direction
    ! lo-1:hi+1 in unused direction
    allocate(slxz  (lo(1):hi(1)+1,lo(2)-1:hi(2)+1,lo(3):hi(3)))
    allocate(srxz  (lo(1):hi(1)+1,lo(2)-1:hi(2)+1,lo(3):hi(3)))
    allocate(simhxz(lo(1):hi(1)+1,lo(2)-1:hi(2)+1,lo(3):hi(3)))

    if (is_conservative) then
       !$OMP PARALLEL DO PRIVATE(i,j,k)
       do k=ks,ke
          do j=js-1,je+1
             do i=is,ie+1
                ! make slxz, srxz by updating 1D extrapolation
                slxz(i,j,k) = slx(i,j,k) &
                     - (dt3/hz)*(simhz(i-1,j,k+1)*wmac(i-1,j,k+1) &
                     - simhz(i-1,j,k)*wmac(i-1,j,k))
                srxz(i,j,k) = srx(i,j,k) &
                     - (dt3/hz)*(simhz(i  ,j,k+1)*wmac(i  ,j,k+1) &
                     - simhz(i  ,j,k)*wmac(i  ,j,k))
             enddo
          enddo
       enddo
       !$OMP END PARALLEL DO
    else
       !$OMP PARALLEL DO PRIVATE(i,j,k)
       do k=ks,ke
          do j=js-1,je+1
             do i=is,ie+1
                ! make slxz, srxz by updating 1D extrapolation
                slxz(i,j,k) = slx(i,j,k) &
                     - (dt6/hz)*(wmac(i-1,j,k+1)+wmac(i-1,j,k)) &
                     *(simhz(i-1,j,k+1)-simhz(i-1,j,k))
                srxz(i,j,k) = srx(i,j,k) &
                     - (dt6/hz)*(wmac(i  ,j,k+1)+wmac(i  ,j,k)) &
                     *(simhz(i  ,j,k+1)-simhz(i  ,j,k))
             enddo
          enddo
       enddo
       !$OMP END PARALLEL DO
    end if

    ! impose lo side bc's
    if (adv_bc(1,1,bccomp) .eq. EXT_DIR) then
       slxz(is,js-1:je+1,ks:ke) = s(is-1,js-1:je+1,ks:ke,comp)
       srxz(is,js-1:je+1,ks:ke) = s(is-1,js-1:je+1,ks:ke,comp)
    else if (adv_bc(1,1,bccomp) .eq. FOEXTRAP .or. &
             adv_bc(1,1,bccomp) .eq. HOEXTRAP) then
       if (is_vel .and. comp .eq. 1) then
          srxz(is,js-1:je+1,ks:ke) = min(srxz(is,js-1:je+1,ks:ke),ZERO)
       end if
       slxz(is,js-1:je+1,ks:ke) = srxz(is,js-1:je+1,ks:ke)
    else if (adv_bc(1,1,bccomp) .eq. REFLECT_EVEN) then
       slxz(is,js-1:je+1,ks:ke) = srxz(is,js-1:je+1,ks:ke)
    else if (adv_bc(1,1,bccomp) .eq. REFLECT_ODD) then
       slxz(is,js-1:je+1,ks:ke) = ZERO
       srxz(is,js-1:je+1,ks:ke) = ZERO
    else if (adv_bc(1,1,bccomp) .eq. INTERIOR) then
    else
       call bl_error("make_edge_scal_3d: invalid boundary type adv_bc(1,1)")
    end if

    ! impose hi side bc's
    if (adv_bc(1,2,bccomp) .eq. EXT_DIR) then
       slxz(ie+1,js-1:je+1,ks:ke) = s(ie+1,js-1:je+1,ks:ke,comp)
       srxz(ie+1,js-1:je+1,ks:ke) = s(ie+1,js-1:je+1,ks:ke,comp)
    else if (adv_bc(1,2,bccomp) .eq. FOEXTRAP .or. &
             adv_bc(1,2,bccomp) .eq. HOEXTRAP) then
       if (is_vel .and. comp .eq. 1) then
          slxz(ie+1,js-1:je+1,ks:ke) = max(slxz(ie+1,js-1:je+1,ks:ke),ZERO)
       end if
       srxz(ie+1,js-1:je+1,ks:ke) = slxz(ie+1,js-1:je+1,ks:ke)
    else if (adv_bc(1,2,bccomp) .eq. REFLECT_EVEN) then
       srxz(ie+1,js-1:je+1,ks:ke) = slxz(ie+1,js-1:je+1,ks:ke)
    else if (adv_bc(1,2,bccomp) .eq. REFLECT_ODD) then
       slxz(ie+1,js-1:je+1,ks:ke) = ZERO
       srxz(ie+1,js-1:je+1,ks:ke) = ZERO
    else if (adv_bc(1,2,bccomp) .eq. INTERIOR) then
    else
       call bl_error("make_edge_scal_3d: invalid boundary type adv_bc(1,2)")
    end if

    !$OMP PARALLEL DO PRIVATE(i,j,k,savg)
    do k=ks,ke
       do j=js-1,je+1
          do i=is,ie+1
             ! make simhxz by solving Riemann problem
             simhxz(i,j,k) = merge(slxz(i,j,k),srxz(i,j,k),umac(i,j,k) .gt. ZERO)
             savg = HALF*(slxz(i,j,k)+srxz(i,j,k))
             simhxz(i,j,k) = merge(simhxz(i,j,k),savg,abs(umac(i,j,k)) .gt. rel_eps)
          enddo
       enddo
    enddo
    !$OMP END PARALLEL DO

    deallocate(slxz,srxz)

    ! loop over appropriate yx faces

    ! These are transverse terms.  The size allocation is tricky.
    ! lo:hi+1 in normal direction
    ! lo:hi in transverse direction
    ! lo-1:hi+1 in unused direction
    allocate(slyx  (lo(1):hi(1),lo(2):hi(2)+1,lo(3)-1:hi(3)+1))
    allocate(sryx  (lo(1):hi(1),lo(2):hi(2)+1,lo(3)-1:hi(3)+1))
    allocate(simhyx(lo(1):hi(1),lo(2):hi(2)+1,lo(3)-1:hi(3)+1))

    if (is_conservative) then
       !$OMP PARALLEL DO PRIVATE(i,j,k)
       do k=ks-1,ke+1
          do j=js,je+1
             do i=is,ie
                ! make slyx, sryx by updating 1D extrapolation
                slyx(i,j,k) = sly(i,j,k) &
                     - (dt3/hx)*(simhx(i+1,j-1,k)*umac(i+1,j-1,k) &
                     - simhx(i,j-1,k)*umac(i,j-1,k))
                sryx(i,j,k) = sry(i,j,k) &
                     - (dt3/hx)*(simhx(i+1,j  ,k)*umac(i+1,j  ,k) &
                     - simhx(i,j  ,k)*umac(i,j  ,k))
             enddo
          enddo
       enddo
       !$OMP END PARALLEL DO
    else
       !$OMP PARALLEL DO PRIVATE(i,j,k)
       do k=ks-1,ke+1
          do j=js,je+1
             do i=is,ie
                ! make slyx, sryx by updating 1D extrapolation
                slyx(i,j,k) = sly(i,j,k) &
                     - (dt6/hx)*(umac(i+1,j-1,k)+umac(i,j-1,k)) &
                     *(simhx(i+1,j-1,k)-simhx(i,j-1,k))
                sryx(i,j,k) = sry(i,j,k) &
                     - (dt6/hx)*(umac(i+1,j  ,k)+umac(i,j  ,k)) &
                     *(simhx(i+1,j  ,k)-simhx(i,j  ,k))
             enddo
          enddo
       enddo
       !$OMP END PARALLEL DO
    end if

    ! impose lo side bc's
    if (adv_bc(2,1,bccomp) .eq. EXT_DIR) then
       slyx(is:ie,js,ks-1:ke+1) = s(is:ie,js-1,ks-1:ke+1,comp)
       sryx(is:ie,js,ks-1:ke+1) = s(is:ie,js-1,ks-1:ke+1,comp)
    else if (adv_bc(2,1,bccomp) .eq. FOEXTRAP .or. &
             adv_bc(2,1,bccomp) .eq. HOEXTRAP) then
       if (is_vel .and. comp .eq. 2) then
          sryx(is:ie,js,ks-1:ke+1) = min(sryx(is:ie,js,ks-1:ke+1),ZERO)
       end if
       slyx(is:ie,js,ks-1:ke+1) = sryx(is:ie,js,ks-1:ke+1)
    else if (adv_bc(2,1,bccomp) .eq. REFLECT_EVEN) then
       slyx(is:ie,js,ks-1:ke+1) = sryx(is:ie,js,ks-1:ke+1)
    else if (adv_bc(2,1,bccomp) .eq. REFLECT_ODD) then
       slyx(is:ie,js,ks-1:ke+1) = ZERO
       sryx(is:ie,js,ks-1:ke+1) = ZERO
    else if (adv_bc(2,1,bccomp) .eq. INTERIOR) then
    else
       call bl_error("make_edge_scal_3d: invalid boundary type adv_bc(2,1)")
    end if

    ! impose hi side bc's
    if (adv_bc(2,2,bccomp) .eq. EXT_DIR) then
       slyx(is:ie,je+1,ks-1:ke+1) = s(is:ie,je+1,ks-1:ke+1,comp)
       sryx(is:ie,je+1,ks-1:ke+1) = s(is:ie,je+1,ks-1:ke+1,comp)
    else if (adv_bc(2,2,bccomp) .eq. FOEXTRAP .or. &
             adv_bc(2,2,bccomp) .eq. HOEXTRAP) then
       if (is_vel .and. comp .eq. 2) then
          slyx(is:ie,je+1,ks-1:ke+1) = max(slyx(is:ie,je+1,ks-1:ke+1),ZERO)
       end if
       sryx(is:ie,je+1,ks-1:ke+1) = slyx(is:ie,je+1,ks-1:ke+1)
    else if (adv_bc(2,2,bccomp) .eq. REFLECT_EVEN) then
       sryx(is:ie,je+1,ks-1:ke+1) = slyx(is:ie,je+1,ks-1:ke+1)
    else if (adv_bc(2,2,bccomp) .eq. REFLECT_ODD) then
       slyx(is:ie,je+1,ks-1:ke+1) = ZERO
       sryx(is:ie,je+1,ks-1:ke+1) = ZERO
    else if (adv_bc(2,2,bccomp) .eq. INTERIOR) then
    else
       call bl_error("make_edge_scal_3d: invalid boundary type adv_bc(2,2)")
    end if

    !$OMP PARALLEL DO PRIVATE(i,j,k,savg)
    do k=ks-1,ke+1
       do j=js,je+1
          do i=is,ie
             ! make simhyx by solving Riemann problem
             simhyx(i,j,k) = merge(slyx(i,j,k),sryx(i,j,k),vmac(i,j,k) .gt. ZERO)
             savg = HALF*(slyx(i,j,k)+sryx(i,j,k))
             simhyx(i,j,k) = merge(simhyx(i,j,k),savg,abs(vmac(i,j,k)) .gt. rel_eps)
          enddo
       enddo
    enddo
    !$OMP END PARALLEL DO

    deallocate(slyx,sryx)

    ! loop over appropriate yz faces

    ! These are transverse terms.  The size allocation is tricky.
    ! lo:hi+1 in normal direction
    ! lo:hi in transverse direction
    ! lo-1:hi+1 in unused direction
    allocate(slyz  (lo(1)-1:hi(1)+1,lo(2):hi(2)+1,lo(3):hi(3)))
    allocate(sryz  (lo(1)-1:hi(1)+1,lo(2):hi(2)+1,lo(3):hi(3)))
    allocate(simhyz(lo(1)-1:hi(1)+1,lo(2):hi(2)+1,lo(3):hi(3)))

    if (is_conservative) then
       !$OMP PARALLEL DO PRIVATE(i,j,k)
       do k=ks,ke
          do j=js,je+1
             do i=is-1,ie+1
                ! make slyz, sryz by updating 1D extrapolation
                slyz(i,j,k) = sly(i,j,k) &
                     - (dt3/hz)*(simhz(i,j-1,k+1)*wmac(i,j-1,k+1) &
                     - simhz(i,j-1,k)*wmac(i,j-1,k))
                sryz(i,j,k) = sry(i,j,k) &
                     - (dt3/hz)*(simhz(i,j  ,k+1)*wmac(i,j  ,k+1) &
                     - simhz(i,j  ,k)*wmac(i,j  ,k))
             enddo
          enddo
       enddo
       !$OMP END PARALLEL DO
    else
       !$OMP PARALLEL DO PRIVATE(i,j,k)
       do k=ks,ke
          do j=js,je+1
             do i=is-1,ie+1
                ! make slyz, sryz by updating 1D extrapolation
                slyz(i,j,k) = sly(i,j,k) &
                     - (dt6/hz)*(wmac(i,j-1,k+1)+wmac(i,j-1,k)) &
                     *(simhz(i,j-1,k+1)-simhz(i,j-1,k))
                sryz(i,j,k) = sry(i,j,k) &
                     - (dt6/hz)*(wmac(i,j  ,k+1)+wmac(i,j  ,k)) &
                     *(simhz(i,j  ,k+1)-simhz(i,j  ,k))
             enddo
          enddo
       enddo
       !$OMP END PARALLEL DO
    end if

    deallocate(simhz)

    ! impose lo side bc's
    if (adv_bc(2,1,bccomp) .eq. EXT_DIR) then
       slyz(is-1:ie+1,js,ks:ke) = s(is-1:ie+1,js-1,ks:ke,comp)
       sryz(is-1:ie+1,js,ks:ke) = s(is-1:ie+1,js-1,ks:ke,comp)
    else if (adv_bc(2,1,bccomp) .eq. FOEXTRAP .or. &
             adv_bc(2,1,bccomp) .eq. HOEXTRAP) then
       if (is_vel .and. comp .eq. 2) then
          sryz(is-1:ie+1,js,ks:ke) = min(sryz(is-1:ie+1,js,ks:ke),ZERO)
       end if
       slyz(is-1:ie+1,js,ks:ke) = sryz(is-1:ie+1,js,ks:ke)
    else if (adv_bc(2,1,bccomp) .eq. REFLECT_EVEN) then
       slyz(is-1:ie+1,js,ks:ke) = sryz(is-1:ie+1,js,ks:ke)
    else if (adv_bc(2,1,bccomp) .eq. REFLECT_ODD) then
       slyz(is-1:ie+1,js,ks:ke) = ZERO
       sryz(is-1:ie+1,js,ks:ke) = ZERO
    else if (adv_bc(2,1,bccomp) .eq. INTERIOR) then
    else
       call bl_error("make_edge_scal_3d: invalid boundary type adv_bc(2,1)")
    end if

    ! impose hi side bc's
    if (adv_bc(2,2,bccomp) .eq. EXT_DIR) then
       slyz(is-1:ie+1,je+1,ks:ke) = s(is-1:ie+1,je+1,ks:ke,comp)
       sryz(is-1:ie+1,je+1,ks:ke) = s(is-1:ie+1,je+1,ks:ke,comp)
    else if (adv_bc(2,2,bccomp) .eq. FOEXTRAP .or. &
             adv_bc(2,2,bccomp) .eq. HOEXTRAP) then
       if (is_vel .and. comp .eq. 2) then
          slyz(is-1:ie+1,je+1,ks:ke) = max(slyz(is-1:ie+1,je+1,ks:ke),ZERO)
       end if
       sryz(is-1:ie+1,je+1,ks:ke) = slyz(is-1:ie+1,je+1,ks:ke)
    else if (adv_bc(2,2,bccomp) .eq. REFLECT_EVEN) then
       sryz(is-1:ie+1,je+1,ks:ke) = slyz(is-1:ie+1,je+1,ks:ke)
    else if (adv_bc(2,2,bccomp) .eq. REFLECT_ODD) then
       slyz(is-1:ie+1,je+1,ks:ke) = ZERO
       sryz(is-1:ie+1,je+1,ks:ke) = ZERO
    else if (adv_bc(2,2,bccomp) .eq. INTERIOR) then
    else
       call bl_error("make_edge_scal_3d: invalid boundary type adv_bc(2,2)")
    end if

    !$OMP PARALLEL DO PRIVATE(i,j,k,savg)
    do k=ks,ke
       do j=js,je+1
          do i=is-1,ie+1
             ! make simhyz by solving Riemann problem
             simhyz(i,j,k) = merge(slyz(i,j,k),sryz(i,j,k),vmac(i,j,k) .gt. ZERO)
             savg = HALF*(slyz(i,j,k)+sryz(i,j,k))
             simhyz(i,j,k) = merge(simhyz(i,j,k),savg,abs(vmac(i,j,k)) .gt. rel_eps)
          enddo
       enddo
    enddo
    !$OMP END PARALLEL DO

    deallocate(slyz,sryz)

    ! loop over appropriate zx faces

    ! These are transverse terms.  The size allocation is tricky.
    ! lo:hi+1 in normal direction
    ! lo:hi in transverse direction
    ! lo-1:hi+1 in unused direction
    allocate(slzx  (lo(1):hi(1),lo(2)-1:hi(2)+1,lo(3):hi(3)+1))
    allocate(srzx  (lo(1):hi(1),lo(2)-1:hi(2)+1,lo(3):hi(3)+1))
    allocate(simhzx(lo(1):hi(1),lo(2)-1:hi(2)+1,lo(3):hi(3)+1))

    if (is_conservative) then
       !$OMP PARALLEL DO PRIVATE(i,j,k)
       do k=ks,ke+1
          do j=js-1,je+1
             do i=is,ie
                ! make slzx, srzx by updating 1D extrapolation
                slzx(i,j,k) = slz(i,j,k) &
                     - (dt3/hx)*(simhx(i+1,j,k-1)*umac(i+1,j,k-1) &
                     - simhx(i,j,k-1)*umac(i,j,k-1))
                srzx(i,j,k) = srz(i,j,k) &
                     - (dt3/hx)*(simhx(i+1,j,k  )*umac(i+1,j,k  ) &
                     - simhx(i,j,k  )*umac(i,j,k  ))
             enddo
          enddo
       enddo
       !$OMP END PARALLEL DO
    else
       !$OMP PARALLEL DO PRIVATE(i,j,k)
       do k=ks,ke+1
          do j=js-1,je+1
             do i=is,ie
                ! make slzx, srzx by updating 1D extrapolation
                slzx(i,j,k) = slz(i,j,k) &
                     - (dt6/hx)*(umac(i+1,j,k-1)+umac(i,j,k-1)) &
                     *(simhx(i+1,j,k-1)-simhx(i,j,k-1))
                srzx(i,j,k) = srz(i,j,k) &
                     - (dt6/hx)*(umac(i+1,j,k  )+umac(i,j,k  )) &
                     *(simhx(i+1,j,k  )-simhx(i,j,k  ))
             enddo
          enddo
       end do
       !$OMP END PARALLEL DO
    end if

    deallocate(simhx)

    ! impose lo side bc's
    if (adv_bc(3,1,bccomp) .eq. EXT_DIR) then
       slzx(is:ie,js-1:je+1,ks) = s(is:ie,js-1:je+1,ks-1,comp)
       srzx(is:ie,js-1:je+1,ks) = s(is:ie,js-1:je+1,ks-1,comp)
    else if (adv_bc(3,1,bccomp) .eq. FOEXTRAP .or. &
             adv_bc(3,1,bccomp) .eq. HOEXTRAP) then
       if (is_vel .and. comp .eq. 3) then
          srzx(is:ie,js-1:je+1,ks) = min(srzx(is:ie,js-1:je+1,ks),ZERO)
       end if
       slzx(is:ie,js-1:je+1,ks) = srzx(is:ie,js-1:je+1,ks)
    else if (adv_bc(3,1,bccomp) .eq. REFLECT_EVEN) then
       slzx(is:ie,js-1:je+1,ks) = srzx(is:ie,js-1:je+1,ks)
    else if (adv_bc(3,1,bccomp) .eq. REFLECT_ODD) then
       slzx(is:ie,js-1:je+1,ks) = ZERO
       srzx(is:ie,js-1:je+1,ks) = ZERO
    else if (adv_bc(3,1,bccomp) .eq. INTERIOR) then
    else
       call bl_error("make_edge_scal_3d: invalid boundary type adv_bc(3,1)")
    end if

    ! impose hi side bc's
    if (adv_bc(3,2,bccomp) .eq. EXT_DIR) then
       slzx(is:ie,js-1:je+1,ke+1) = s(is:ie,js-1:je+1,ke+1,comp)
       srzx(is:ie,js-1:je+1,ke+1) = s(is:ie,js-1:je+1,ke+1,comp)
    else if (adv_bc(3,2,bccomp) .eq. FOEXTRAP .or. &
             adv_bc(3,2,bccomp) .eq. HOEXTRAP) then
       if (is_vel .and. comp .eq. 3) then
          slzx(is:ie,js-1:je+1,ke+1) = max(slzx(is:ie,js-1:je+1,ke+1),ZERO)
       end if
       srzx(is:ie,js-1:je+1,ke+1) = slzx(is:ie,js-1:je+1,ke+1)
    else if (adv_bc(3,2,bccomp) .eq. REFLECT_EVEN) then
       srzx(is:ie,js-1:je+1,ke+1) = slzx(is:ie,js-1:je+1,ke+1)
    else if (adv_bc(3,2,bccomp) .eq. REFLECT_ODD) then
       slzx(is:ie,js-1:je+1,ke+1) = ZERO
       srzx(is:ie,js-1:je+1,ke+1) = ZERO
    else if (adv_bc(3,2,bccomp) .eq. INTERIOR) then
    else
       call bl_error("make_edge_scal_3d: invalid boundary type adv_bc(3,2)")
    end if

    !$OMP PARALLEL DO PRIVATE(i,j,k,savg)
    do k=ks,ke+1
       do j=js-1,je+1
          do i=is,ie
             ! make simhzx by solving Riemann problem
             simhzx(i,j,k) = merge(slzx(i,j,k),srzx(i,j,k),wmac(i,j,k) .gt. ZERO)
             savg = HALF*(slzx(i,j,k)+srzx(i,j,k))
             simhzx(i,j,k) = merge(simhzx(i,j,k),savg,abs(wmac(i,j,k)) .gt. rel_eps)
          enddo
       enddo
    enddo
    !$OMP END PARALLEL DO

    deallocate(slzx,srzx)

    ! loop over appropriate zy faces

    ! These are transverse terms.  The size allocation is tricky.
    ! lo:hi+1 in normal direction
    ! lo:hi in transverse direction
    ! lo-1:hi+1 in unused direction
    allocate(slzy  (lo(1)-1:hi(1)+1,lo(2):hi(2),lo(3):hi(3)+1))
    allocate(srzy  (lo(1)-1:hi(1)+1,lo(2):hi(2),lo(3):hi(3)+1))
    allocate(simhzy(lo(1)-1:hi(1)+1,lo(2):hi(2),lo(3):hi(3)+1))

    if (is_conservative) then
       !$OMP PARALLEL DO PRIVATE(i,j,k)
       do k=ks,ke+1
          do j=js,je
             do i=is-1,ie+1
                ! make slzy, srzy by updating 1D extrapolation
                slzy(i,j,k) = slz(i,j,k) &
                     - (dt3/hy)*(simhy(i,j+1,k-1)*vmac(i,j+1,k-1) &
                     - simhy(i,j,k-1)*vmac(i,j,k-1))
                srzy(i,j,k) = srz(i,j,k) &
                     - (dt3/hy)*(simhy(i,j+1,k  )*vmac(i,j+1,k  ) &
                     - simhy(i,j,k  )*vmac(i,j,k  ))
             enddo
          enddo
       enddo
       !$OMP END PARALLEL DO
    else
       !$OMP PARALLEL DO PRIVATE(i,j,k)
       do k=ks,ke+1
          do j=js,je
             do i=is-1,ie+1
                ! make slzy, srzy by updating 1D extrapolation
                slzy(i,j,k) = slz(i,j,k) &
                     - (dt6/hy)*(vmac(i,j+1,k-1)+vmac(i,j,k-1)) &
                     *(simhy(i,j+1,k-1)-simhy(i,j,k-1))
                srzy(i,j,k) = srz(i,j,k) &
                     - (dt6/hy)*(vmac(i,j+1,k  )+vmac(i,j,k  )) &
                     *(simhy(i,j+1,k  )-simhy(i,j,k  ))
             enddo
          enddo
       enddo
       !$OMP END PARALLEL DO
    end if

    deallocate(simhy)

    ! impose lo side bc's
    if (adv_bc(3,1,bccomp) .eq. EXT_DIR) then
       slzy(is-1:ie+1,js:je,ks) = s(is-1:ie+1,js:je,ks-1,comp)
       srzy(is-1:ie+1,js:je,ks) = s(is-1:ie+1,js:je,ks-1,comp)
    else if (adv_bc(3,1,bccomp) .eq. FOEXTRAP .or. &
             adv_bc(3,1,bccomp) .eq. HOEXTRAP) then
       if (is_vel .and. comp .eq. 3) then
          srzy(is-1:ie+1,js:je,ks) = min(srzy(is-1:ie+1,js:je,ks),ZERO)
       end if
       slzy(is-1:ie+1,js:je,ks) = srzy(is-1:ie+1,js:je,ks)
    else if (adv_bc(3,1,bccomp) .eq. REFLECT_EVEN) then
       slzy(is-1:ie+1,js:je,ks) = srzy(is-1:ie+1,js:je,ks)
    else if (adv_bc(3,1,bccomp) .eq. REFLECT_ODD) then
       slzy(is-1:ie+1,js:je,ks) = ZERO
       srzy(is-1:ie+1,js:je,ks) = ZERO
    else if (adv_bc(3,1,bccomp) .eq. INTERIOR) then
    else
       call bl_error("make_edge_scal_3d: invalid boundary type adv_bc(3,1)")
    end if

    ! impose hi side bc's
    if (adv_bc(3,2,bccomp) .eq. EXT_DIR) then
       slzy(is-1:ie+1,js:je,ke+1) = s(is-1:ie+1,js:je,ke+1,comp)
       srzy(is-1:ie+1,js:je,ke+1) = s(is-1:ie+1,js:je,ke+1,comp)
    else if (adv_bc(3,2,bccomp) .eq. FOEXTRAP .or. &
             adv_bc(3,2,bccomp) .eq. HOEXTRAP) then
       if (is_vel .and. comp .eq. 3) then
          slzy(is-1:ie+1,js:je,ke+1) = max(slzy(is-1:ie+1,js:je,ke+1),ZERO)
       end if
       srzy(is-1:ie+1,js:je,ke+1) = slzy(is-1:ie+1,js:je,ke+1)
    else if (adv_bc(3,2,bccomp) .eq. REFLECT_EVEN) then
       srzy(is-1:ie+1,js:je,ke+1) = slzy(is-1:ie+1,js:je,ke+1)
    else if (adv_bc(3,2,bccomp) .eq. REFLECT_ODD) then
       slzy(is-1:ie+1,js:je,ke+1) = ZERO
       srzy(is-1:ie+1,js:je,ke+1) = ZERO
    else if (adv_bc(3,2,bccomp) .eq. INTERIOR) then
    else
       call bl_error("make_edge_scal_3d: invalid boundary type adv_bc(3,2)")
    end if

    !$OMP PARALLEL DO PRIVATE(i,j,k,savg)
    do k=ks,ke+1
       do j=js,je
          do i=is-1,ie+1
             ! make simhzy by solving Riemann problem
             simhzy(i,j,k) = merge(slzy(i,j,k),srzy(i,j,k),wmac(i,j,k) .gt. ZERO)
             savg = HALF*(slzy(i,j,k)+srzy(i,j,k))
             simhzy(i,j,k) = merge(simhzy(i,j,k),savg,abs(wmac(i,j,k)) .gt. rel_eps)
          enddo
       enddo
    enddo
    !$OMP END PARALLEL DO

    deallocate(slzy,srzy)

    !******************************************************************
    ! Create sedgelx, etc.
    !******************************************************************

    ! Final edge states.
    ! lo:hi+1 in the normal direction
    ! lo:hi in the transverse directions
    allocate(sedgelx(lo(1):hi(1)+1,lo(2):hi(2),lo(3):hi(3)))
    allocate(sedgerx(lo(1):hi(1)+1,lo(2):hi(2),lo(3):hi(3)))

    ! loop over appropriate x-faces
    if (is_conservative) then
       !$OMP PARALLEL DO PRIVATE(i,j,k,fl,fr)
       do k=ks,ke
          do j=js,je
             do i=is,ie+1
                ! make sedgelx, sedgerx
                fl = merge(force(i-1,j,k,comp), Ipf(i-1,j,k,1), ppm_trace_forces == 0)
                fr = merge(force(i  ,j,k,comp), Imf(i,  j,k,1), ppm_trace_forces == 0)

                sedgelx(i,j,k) = slx(i,j,k) &
                     - (dt2/hy)*(simhyz(i-1,j+1,k  )*vmac(i-1,j+1,k  ) &
                     - simhyz(i-1,j,k)*vmac(i-1,j,k)) &
                     - (dt2/hz)*(simhzy(i-1,j  ,k+1)*wmac(i-1,j  ,k+1) &
                     - simhzy(i-1,j,k)*wmac(i-1,j,k)) &
                     - (dt2/hx)*s(i-1,j,k,comp)*(umac(i  ,j,k)-umac(i-1,j,k)) &
                     + dt2*fl

                sedgerx(i,j,k) = srx(i,j,k) &
                     - (dt2/hy)*(simhyz(i  ,j+1,k  )*vmac(i  ,j+1,  k) &
                     - simhyz(i  ,j,k)*vmac(i  ,j,k)) &
                     - (dt2/hz)*(simhzy(i  ,j  ,k+1)*wmac(i  ,j  ,k+1) &
                     - simhzy(i  ,j,k)*wmac(i  ,j,k)) &
                     - (dt2/hx)*s(i  ,j,k,comp)*(umac(i+1,j,k)-umac(i  ,j,k)) &
                     + dt2*fr
             end do
          end do
       end do
       !$OMP END PARALLEL DO
    else
       !$OMP PARALLEL DO PRIVATE(i,j,k,fl,fr)
       do k=ks,ke
          do j=js,je
             do i=is,ie+1
                ! make sedgelx, sedgerx
                fl = merge(force(i-1,j,k,comp), Ipf(i-1,j,k,1), ppm_trace_forces == 0)
                fr = merge(force(i  ,j,k,comp), Imf(i,  j,k,1), ppm_trace_forces == 0)

                sedgelx(i,j,k) = slx(i,j,k) &
                     - (dt4/hy)*(vmac(i-1,j+1,k  )+vmac(i-1,j,k))* &
                     (simhyz(i-1,j+1,k  )-simhyz(i-1,j,k)) &
                     - (dt4/hz)*(wmac(i-1,j  ,k+1)+wmac(i-1,j,k))* &
                     (simhzy(i-1,j  ,k+1)-simhzy(i-1,j,k)) &
                     + dt2*fl

                sedgerx(i,j,k) = srx(i,j,k) &
                     - (dt4/hy)*(vmac(i  ,j+1,k  )+vmac(i  ,j,k))* &
                     (simhyz(i  ,j+1,k  )-simhyz(i  ,j,k)) &
                     - (dt4/hz)*(wmac(i  ,j  ,k+1)+wmac(i  ,j,k))* &
                     (simhzy(i  ,j  ,k+1)-simhzy(i  ,j,k)) &
                     + dt2*fr
             end do
          end do
       end do
       !$OMP END PARALLEL DO
    end if

    deallocate(slx,srx,simhyz,simhzy)

    !$OMP PARALLEL DO PRIVATE(i,j,k,savg)
    do k=ks,ke
       do j=js,je
          do i=is,ie+1
             ! make sedgex by solving Riemann problem
             ! boundary conditions enforced outside of i,j,k loop
             sedgex(i,j,k,comp) = merge(sedgelx(i,j,k),sedgerx(i,j,k),umac(i,j,k) .gt. ZERO)
             savg = HALF*(sedgelx(i,j,k)+sedgerx(i,j,k))
             sedgex(i,j,k,comp) = merge(sedgex(i,j,k,comp),savg,abs(umac(i,j,k)).gt.rel_eps)
          enddo
       enddo
    enddo
    !$OMP END PARALLEL DO

    ! impose lo side bc's
    if (adv_bc(1,1,bccomp) .eq. EXT_DIR) then
       sedgex(is,js:je,ks:ke,comp) = s(is-1,js:je,ks:ke,comp)
    else if (adv_bc(1,1,bccomp) .eq. FOEXTRAP .or. &
             adv_bc(1,1,bccomp) .eq. HOEXTRAP) then
       if (is_vel .and. comp .eq. 1) then
          sedgex(is,js:je,ks:ke,comp) = min(sedgerx(is,js:je,ks:ke),ZERO)
       else
          sedgex(is,js:je,ks:ke,comp) = sedgerx(is,js:je,ks:ke)
       end if
    else if (adv_bc(1,1,bccomp) .eq. REFLECT_EVEN) then
       sedgex(is,js:je,ks:ke,comp) = sedgerx(is,js:je,ks:ke)
    else if (adv_bc(1,1,bccomp) .eq. REFLECT_ODD) then
       sedgex(is,js:je,ks:ke,comp) = ZERO
    else if (adv_bc(1,1,bccomp) .eq. INTERIOR) then
    else
       call bl_error("make_edge_scal_3d: invalid boundary type adv_bc(1,1)")
    end if

    ! impose hi side bc's
    if (adv_bc(1,2,bccomp) .eq. EXT_DIR) then
       sedgex(ie+1,js:je,ks:ke,comp) = s(ie+1,js:je,ks:ke,comp)
    else if (adv_bc(1,2,bccomp) .eq. FOEXTRAP .or. &
             adv_bc(1,2,bccomp) .eq. HOEXTRAP) then
       if (is_vel .and. comp .eq. 1) then
          sedgex(ie+1,js:je,ks:ke,comp) = max(sedgelx(ie+1,js:je,ks:ke),ZERO)
       else
          sedgex(ie+1,js:je,ks:ke,comp) = sedgelx(ie+1,js:je,ks:ke)
       end if
    else if (adv_bc(1,2,bccomp) .eq. REFLECT_EVEN) then
       sedgex(ie+1,js:je,ks:ke,comp) = sedgelx(ie+1,js:je,ks:ke)
    else if (adv_bc(1,2,bccomp) .eq. REFLECT_ODD) then
       sedgex(ie+1,js:je,ks:ke,comp) = ZERO
    else if (adv_bc(1,2,bccomp) .eq. INTERIOR) then
    else
       call bl_error("make_edge_scal_3d: invalid boundary type adv_bc(1,2)")
    end if

    deallocate(sedgelx,sedgerx)

    allocate(sedgely(lo(1):hi(1),lo(2):hi(2)+1,lo(3):hi(3)))
    allocate(sedgery(lo(1):hi(1),lo(2):hi(2)+1,lo(3):hi(3)))

    ! loop over appropriate y-faces
    if (is_conservative) then
       !$OMP PARALLEL DO PRIVATE(i,j,k,fl,fr)
       do k=ks,ke
          do j=js,je+1
             do i=is,ie
                ! make sedgely, sedgery
                fl = merge(force(i,j-1,k,comp), Ipf(i,j-1,k,2), ppm_trace_forces == 0)
                fr = merge(force(i,j  ,k,comp), Imf(i,j  ,k,2), ppm_trace_forces == 0)
                
                sedgely(i,j,k) = sly(i,j,k) &
                     - (dt2/hx)*(simhxz(i+1,j-1,k  )*umac(i+1,j-1,k  ) &
                     - simhxz(i,j-1,k)*umac(i,j-1,k)) &
                     - (dt2/hz)*(simhzx(i  ,j-1,k+1)*wmac(i  ,j-1,k+1) &
                     - simhzx(i,j-1,k)*wmac(i,j-1,k)) &
                     - (dt2/hy)*s(i,j-1,k,comp)*(vmac(i,j  ,k)-vmac(i,j-1,k)) &
                     + dt2*fl

                sedgery(i,j,k) = sry(i,j,k) &
                     - (dt2/hx)*(simhxz(i+1,j  ,k  )*umac(i+1,j  ,k  ) &
                     - simhxz(i,j  ,k)*umac(i,j  ,k)) &
                     - (dt2/hz)*(simhzx(i  ,j  ,k+1)*wmac(i  ,j  ,k+1) &
                     - simhzx(i,j  ,k)*wmac(i,j  ,k)) &
                     - (dt2/hy)*s(i,j  ,k,comp)*(vmac(i,j+1,k)-vmac(i,j  ,k)) &
                     + dt2*fr
             end do
          end do
       end do
       !$OMP END PARALLEL DO
    else
       !$OMP PARALLEL DO PRIVATE(i,j,k,fl,fr)
       do k=ks,ke
          do j=js,je+1
             do i=is,ie
                ! make sedgely, sedgery
                fl = merge(force(i,j-1,k,comp), Ipf(i,j-1,k,2), ppm_trace_forces == 0)
                fr = merge(force(i,j  ,k,comp), Imf(i,j  ,k,2), ppm_trace_forces == 0)

                sedgely(i,j,k) = sly(i,j,k) &
                     - (dt4/hx)*(umac(i+1,j-1,k  )+umac(i,j-1,k))* &
                     (simhxz(i+1,j-1,k  )-simhxz(i,j-1,k)) &
                     - (dt4/hz)*(wmac(i  ,j-1,k+1)+wmac(i,j-1,k))* &
                     (simhzx(i  ,j-1,k+1)-simhzx(i,j-1,k)) &
                     + dt2*fl

                sedgery(i,j,k) = sry(i,j,k) &
                     - (dt4/hx)*(umac(i+1,j  ,k  )+umac(i,j  ,k))* &
                     (simhxz(i+1,j  ,k  )-simhxz(i,j  ,k)) &
                     - (dt4/hz)*(wmac(i  ,j  ,k+1)+wmac(i,j  ,k))* &
                     (simhzx(i  ,j  ,k+1)-simhzx(i,j  ,k)) &
                     + dt2*fr
             end do
          end do
       end do
       !$OMP END PARALLEL DO
    end if

    deallocate(sly,sry,simhxz,simhzx)

    !$OMP PARALLEL DO PRIVATE(i,j,k,savg)
    do k=ks,ke
       do j=js,je+1
          do i=is,ie
             ! make sedgey by solving Riemann problem
             ! boundary conditions enforced outside of i,j,k loop
             sedgey(i,j,k,comp) = merge(sedgely(i,j,k),sedgery(i,j,k),vmac(i,j,k) .gt. ZERO)
             savg = HALF*(sedgely(i,j,k)+sedgery(i,j,k))
             sedgey(i,j,k,comp) = merge(sedgey(i,j,k,comp),savg,abs(vmac(i,j,k)).gt.rel_eps)
          enddo
       enddo
    enddo
    !$OMP END PARALLEL DO

    ! impose lo side bc's
    if (adv_bc(2,1,bccomp) .eq. EXT_DIR) then
       sedgey(is:ie,js,ks:ke,comp) = s(is:ie,js-1,ks:ke,comp)
    else if (adv_bc(2,1,bccomp) .eq. FOEXTRAP .or. &
             adv_bc(2,1,bccomp) .eq. HOEXTRAP) then
       if (is_vel .and. comp .eq. 2) then
          sedgey(is:ie,js,ks:ke,comp) = min(sedgery(is:ie,js,ks:ke),ZERO)
       else
          sedgey(is:ie,js,ks:ke,comp) = sedgery(is:ie,js,ks:ke)
       end if
    else if (adv_bc(2,1,bccomp) .eq. REFLECT_EVEN) then
       sedgey(is:ie,js,ks:ke,comp) = sedgery(is:ie,js,ks:ke)
    else if (adv_bc(2,1,bccomp) .eq. REFLECT_ODD) then
       sedgey(is:ie,js,ks:ke,comp) = ZERO
    else if (adv_bc(2,1,bccomp) .eq. INTERIOR) then
    else
       call bl_error("make_edge_scal_3d: invalid boundary type adv_bc(2,1)")
    end if

    ! impose hi side bc's
    if (adv_bc(2,2,bccomp) .eq. EXT_DIR) then
       sedgey(is:ie,je+1,ks:ke,comp) = s(is:ie,je+1,ks:ke,comp)
    else if (adv_bc(2,2,bccomp) .eq. FOEXTRAP .or. &
             adv_bc(2,2,bccomp) .eq. HOEXTRAP) then
       if (is_vel .and. comp .eq. 2) then
          sedgey(is:ie,je+1,ks:ke,comp) = max(sedgely(is:ie,je+1,ks:ke),ZERO)
       else
          sedgey(is:ie,je+1,ks:ke,comp) = sedgely(is:ie,je+1,ks:ke)
       end if
    else if (adv_bc(2,2,bccomp) .eq. REFLECT_EVEN) then
       sedgey(is:ie,je+1,ks:ke,comp) = sedgely(is:ie,je+1,ks:ke)
    else if (adv_bc(2,2,bccomp) .eq. REFLECT_ODD) then
       sedgey(is:ie,je+1,ks:ke,comp) = ZERO
    else if (adv_bc(2,2,bccomp) .eq. INTERIOR) then
    else
       call bl_error("make_edge_scal_3d: invalid boundary type adv_bc(2,2)")
    end if

    deallocate(sedgely,sedgery)

    allocate(sedgelz(lo(1):hi(1),lo(2):hi(2),lo(3):hi(3)+1))
    allocate(sedgerz(lo(1):hi(1),lo(2):hi(2),lo(3):hi(3)+1))

    ! loop over appropriate z-faces
    if (is_conservative) then
       !$OMP PARALLEL DO PRIVATE(i,j,k,fl,fr)
       do k=ks,ke+1
          do j=js,je
             do i=is,ie
                ! make sedgelz, sedgerz
                fl = merge(force(i,j,k-1,comp), Ipf(i,j,k-1,3), ppm_trace_forces == 0)
                fr = merge(force(i,j,k  ,comp), Imf(i,j,k  ,3), ppm_trace_forces == 0)                

                sedgelz(i,j,k) = slz(i,j,k) &
                     - (dt2/hx)*(simhxy(i+1,j  ,k-1)*umac(i+1,j  ,k-1) &
                     - simhxy(i,j,k-1)*umac(i,j,k-1)) &
                     - (dt2/hy)*(simhyx(i  ,j+1,k-1)*vmac(i  ,j+1,k-1) &
                     - simhyx(i,j,k-1)*vmac(i,j,k-1)) &
                     - (dt2/hz)*s(i,j,k-1,comp)*(wmac(i,j,k  )-wmac(i,j,k-1)) &
                     + dt2*fl

                sedgerz(i,j,k) = srz(i,j,k) &
                     - (dt2/hx)*(simhxy(i+1,j  ,k  )*umac(i+1,j  ,k  ) &
                     - simhxy(i,j,k  )*umac(i,j,k  )) &
                     - (dt2/hy)*(simhyx(i  ,j+1,k  )*vmac(i  ,j+1,k  ) &
                     - simhyx(i,j,k  )*vmac(i,j,k  )) &
                     - (dt2/hz)*s(i,j,k  ,comp)*(wmac(i,j,k+1)-wmac(i,j,k  )) &
                     + dt2*fr
             end do
          end do
       end do
       !$OMP END PARALLEL DO
    else
       !$OMP PARALLEL DO PRIVATE(i,j,k,fl,fr)
       do k=ks,ke+1
          do j=js,je
             do i=is,ie
                ! make sedgelz, sedgerz
                fl = merge(force(i,j,k-1,comp), Ipf(i,j,k-1,3), ppm_trace_forces == 0)
                fr = merge(force(i,j,k  ,comp), Imf(i,j,k  ,3), ppm_trace_forces == 0)                

                sedgelz(i,j,k) = slz(i,j,k) &
                     - (dt4/hx)*(umac(i+1,j  ,k-1)+umac(i,j,k-1)) &
                     *(simhxy(i+1,j  ,k-1)-simhxy(i,j,k-1)) &
                     - (dt4/hy)*(vmac(i  ,j+1,k-1)+vmac(i,j,k-1)) &
                     *(simhyx(i  ,j+1,k-1)-simhyx(i,j,k-1)) &
                     + dt2*fl

                sedgerz(i,j,k) = srz(i,j,k) &
                     - (dt4/hx)*(umac(i+1,j  ,k  )+umac(i,j,k  )) &
                     *(simhxy(i+1,j  ,k  )-simhxy(i,j,k  )) &
                     - (dt4/hy)*(vmac(i  ,j+1,k  )+vmac(i,j,k  )) &
                     *(simhyx(i  ,j+1,k  )-simhyx(i,j,k  )) &
                     + dt2*fr
             end do
          end do
       end do
       !$OMP END PARALLEL DO
    end if

    deallocate(slz,srz,simhxy,simhyx)

    !$OMP PARALLEL DO PRIVATE(i,j,k,savg)
    do k=ks,ke+1
       do j=js,je
          do i=is,ie
             ! make sedgez by solving Riemann problem
             ! boundary conditions enforced outside of i,j,k loop
             sedgez(i,j,k,comp) = merge(sedgelz(i,j,k),sedgerz(i,j,k),wmac(i,j,k) .gt. ZERO)
             savg = HALF*(sedgelz(i,j,k)+sedgerz(i,j,k))
             sedgez(i,j,k,comp) = merge(sedgez(i,j,k,comp),savg,abs(wmac(i,j,k)).gt.rel_eps)
          enddo
       enddo
    enddo
    !$OMP END PARALLEL DO

    ! impose lo side bc's
    if (adv_bc(3,1,bccomp) .eq. EXT_DIR) then
       sedgez(is:ie,js:je,ks,comp) = s(is:ie,js:je,ks-1,comp)
    else if (adv_bc(3,1,bccomp) .eq. FOEXTRAP .or. &
             adv_bc(3,1,bccomp) .eq. HOEXTRAP) then
       if (is_vel .and. comp .eq. 3) then
          sedgez(is:ie,js:je,ks,comp) = min(sedgerz(is:ie,js:je,ks),ZERO)
       else
          sedgez(is:ie,js:je,ks,comp) = sedgerz(is:ie,js:je,ks)
       end if
    else if (adv_bc(3,1,bccomp) .eq. REFLECT_EVEN) then
       sedgez(is:ie,js:je,ks,comp) = sedgerz(is:ie,js:je,ks)
    else if (adv_bc(3,1,bccomp) .eq. REFLECT_ODD) then
       sedgez(is:ie,js:je,ks,comp) = ZERO
    else if (adv_bc(3,1,bccomp) .eq. INTERIOR) then
    else
       call bl_error("make_edge_scal_3d: invalid boundary type adv_bc(3,1)")
    end if

    ! impose hi side bc's
    if (adv_bc(3,2,bccomp) .eq. EXT_DIR) then
       sedgez(is:ie,js:je,ke+1,comp) = s(is:ie,js:je,ke+1,comp)
    else if (adv_bc(3,2,bccomp) .eq. FOEXTRAP .or. &
             adv_bc(3,2,bccomp) .eq. HOEXTRAP) then
       if (is_vel .and. comp .eq. 3) then
          sedgez(is:ie,js:je,ke+1,comp) = max(sedgelz(is:ie,js:je,ke+1),ZERO)
       else
          sedgez(is:ie,js:je,ke+1,comp) = sedgelz(is:ie,js:je,ke+1)
       end if
    else if (adv_bc(3,2,bccomp) .eq. REFLECT_EVEN) then
       sedgez(is:ie,js:je,ke+1,comp) = sedgelz(is:ie,js:je,ke+1)
    else if (adv_bc(3,2,bccomp) .eq. REFLECT_ODD) then
       sedgez(is:ie,js:je,ke+1,comp) = ZERO
    else if (adv_bc(3,2,bccomp) .eq. INTERIOR) then
    else
       call bl_error("make_edge_scal_3d: invalid boundary type adv_bc(3,2)")
    end if

    deallocate(sedgelz,sedgerz)

  end subroutine make_edge_scal_3d

end module make_edge_scal_module
