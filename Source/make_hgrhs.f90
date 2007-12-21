module hgrhs_module

  use bl_types
  use multifab_module
  
  implicit none

  private

  public :: make_hgrhs

contains
  
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  
  subroutine make_hgrhs(nlevs,hgrhs,Source,gamma1_term,Sbar,div_coeff,dx)

    use bl_constants_module
    use geometry, only: spherical
    use fill_3d_module
    
    integer        , intent(in   ) :: nlevs
    type(multifab) , intent(inout) :: hgrhs(:)
    type(multifab) , intent(in   ) :: Source(:)
    type(multifab) , intent(in   ) :: gamma1_term(:)
    real(kind=dp_t), intent(in   ) :: Sbar(:,0:)
    real(kind=dp_t), intent(in   ) :: div_coeff(:,0:)
    real(kind=dp_t), intent(in   ) :: dx(:,:)
    
    type(multifab), allocatable  :: rhs_cc(:)
    type(multifab), allocatable  :: Sbar_cart(:)
    type(multifab), allocatable  :: div_coeff_cart(:)
    real(kind=dp_t), pointer:: hp(:,:,:,:),gp(:,:,:,:),rp(:,:,:,:)
    real(kind=dp_t), pointer:: dp(:,:,:,:),sp(:,:,:,:),sbp(:,:,:,:)
    integer :: lo(Source(1)%dim),hi(Source(1)%dim)
    integer :: i,dm,n
    
    dm = Source(1)%dim

    allocate(rhs_cc(nlevs))
    if (spherical .eq. 1) then
       allocate(Sbar_cart(nlevs))
       allocate(div_coeff_cart(nlevs))
    end if

    do n = 1, nlevs
       call multifab_build(rhs_cc(n),Source(n)%la,1,1)
       call setval(rhs_cc(n),ZERO,all=.true.)
    enddo
    if(spherical .eq. 1) then
       do n = 1, nlevs
          call multifab_build(Sbar_cart(n),Source(n)%la,1,0)
          call multifab_build(div_coeff_cart(n),Source(n)%la,1,0)
          call setval(Sbar_cart(n),ZERO,all=.true.)
          call setval(div_coeff_cart(n),ZERO,all=.true.)
       enddo
    endif
    
    if (spherical .eq. 1) then
       call fill_3d_data_wrapper(nlevs,div_coeff_cart,div_coeff,dx)
       call fill_3d_data_wrapper(nlevs,Sbar_cart,Sbar,dx)
    end if

    do n = 1, nlevs
       
       do i = 1, Source(n)%nboxes
          if ( multifab_remote(Source(n), i) ) cycle
          rp => dataptr(rhs_cc(n), i)
          sp => dataptr(Source(n), i)
          lo =  lwb(get_box(Source(n), i))
          hi =  upb(get_box(Source(n), i))
          select case (dm)
          case (2)
             gp => dataptr(gamma1_term(n), i)
             call make_rhscc_2d(lo,hi,rp(:,:,1,1),sp(:,:,1,1),gp(:,:,1,1),Sbar(n,:), &
                                div_coeff(n,:),dx(n,:))
          case (3)
             if (spherical .eq. 1) then
                dp => dataptr(div_coeff_cart(n), i)
                sbp => dataptr(Sbar_cart(n), i)
                call make_rhscc_3d_sphr(lo,hi,rp(:,:,:,1),sp(:,:,:,1),sbp(:,:,:,1), &
                                        dp(:,:,:,1))
             else
                call make_rhscc_3d_cart(lo,hi,rp(:,:,:,1),sp(:,:,:,1),Sbar(n,:), &
                                        div_coeff(n,:),dx(n,:))
             endif
          end select
       end do
       call multifab_fill_boundary(rhs_cc(n))
       
       call setval(hgrhs(n),ZERO,all=.true.)
       do i = 1, Source(n)%nboxes
          if ( multifab_remote(Source(n), i) ) cycle
          hp => dataptr(hgrhs(n), i)
          rp => dataptr(rhs_cc(n), i)
          lo =  lwb(get_box(Source(n), i))
          hi =  upb(get_box(Source(n), i))
          select case (dm)
          case (2)
             call make_hgrhs_2d(lo,hi,hp(:,:,1,1),rp(:,:,1,1))
          case (3)
             call make_hgrhs_3d(lo,hi,hp(:,:,:,1),rp(:,:,:,1))
          end select
       end do
       call multifab_fill_boundary(hgrhs(n))
       
    enddo ! end loop over levels
    
    do n = 1, nlevs
       call multifab_destroy(rhs_cc(n))
       if (spherical .eq. 1) then
          call multifab_destroy(Sbar_cart(n))
          call multifab_destroy(div_coeff_cart(n))
       end if
    enddo
    
  end subroutine make_hgrhs
  
  subroutine make_rhscc_2d(lo,hi,rhs_cc,Source,gamma1_term,Sbar,div_coeff,dx)

    integer         , intent(in   ) :: lo(:), hi(:)
    real (kind=dp_t), intent(  out) :: rhs_cc(lo(1)-1:,lo(2)-1:)
    real (kind=dp_t), intent(in   ) :: Source(lo(1):,lo(2):)
    real (kind=dp_t), intent(in   ) :: gamma1_term(lo(1):,lo(2):)  
    real (kind=dp_t), intent(in   ) ::      Sbar(0:)
    real (kind=dp_t), intent(in   ) :: div_coeff(0:)
    real (kind=dp_t), intent(in   ) :: dx(:)
    
    ! Local variables
    integer :: i, j
    
    do j = lo(2),hi(2)
       do i = lo(1),hi(1)
          rhs_cc(i,j) = div_coeff(j) * (Source(i,j) - Sbar(j) + gamma1_term(i,j))
       end do
    end do
    
  end subroutine make_rhscc_2d
  
  subroutine make_hgrhs_2d(lo,hi,rhs,rhs_cc)

    use bl_constants_module

    integer         , intent(in   ) :: lo(:), hi(:)
    real (kind=dp_t), intent(  out) :: rhs(lo(1):,lo(2):)  
    real (kind=dp_t), intent(in   ) :: rhs_cc(lo(1)-1:,lo(2)-1:)
    
    ! Local variables
    integer :: i, j
    
    do j = lo(2),hi(2)+1
       do i = lo(1), hi(1)+1
          rhs(i,j) = FOURTH * ( rhs_cc(i,j  ) + rhs_cc(i-1,j  ) &
               + rhs_cc(i,j-1) + rhs_cc(i-1,j-1) )
       enddo
    enddo
    
  end subroutine make_hgrhs_2d
  
  subroutine make_rhscc_3d_cart(lo,hi,rhs_cc,Source,Sbar,div_coeff,dx)

    integer         , intent(in   ) :: lo(:), hi(:)
    real (kind=dp_t), intent(  out) :: rhs_cc(lo(1)-1:,lo(2)-1:,lo(3)-1:)  
    real (kind=dp_t), intent(in   ) :: Source(lo(1):,lo(2):,lo(3):)  
    real (kind=dp_t), intent(in   ) :: Sbar(0:)
    real (kind=dp_t), intent(in   ) :: div_coeff(0:)
    real (kind=dp_t), intent(in   ) :: dx(:)
    
    ! Local variables
    integer :: i,j,k
    
    do k = lo(3),hi(3)
       do j = lo(2),hi(2)
          do i = lo(1),hi(1)
             rhs_cc(i,j,k) = div_coeff(k) * (Source(i,j,k) - Sbar(k))
          end do
       end do
    end do
    
  end subroutine make_rhscc_3d_cart
   
  subroutine make_rhscc_3d_sphr(lo,hi,rhs_cc,Source,Sbar_cart,div_coeff_cart)

    integer         , intent(in   ) :: lo(:), hi(:)
    real (kind=dp_t), intent(  out) ::         rhs_cc(lo(1)-1:,lo(2)-1:,lo(3)-1:)  
    real (kind=dp_t), intent(in   ) ::         Source(lo(1)  :,lo(2)  :,lo(3)  :)  
    real (kind=dp_t), intent(in   ) ::      Sbar_cart(lo(1)  :,lo(2)  :,lo(3)  :)  
    real (kind=dp_t), intent(in   ) :: div_coeff_cart(lo(1)  :,lo(2)  :,lo(3)  :)  
    
    ! Local variables
    integer :: i, j,k
    
    do k = lo(3),hi(3)
       do j = lo(2),hi(2)
          do i = lo(1),hi(1)
             rhs_cc(i,j,k) = div_coeff_cart(i,j,k) * (Source(i,j,k) - Sbar_cart(i,j,k))
             
          end do
       end do
    end do
    
  end subroutine make_rhscc_3d_sphr
  
  subroutine make_hgrhs_3d(lo,hi,rhs,rhs_cc)

    use bl_constants_module

    integer         , intent(in   ) :: lo(:), hi(:)
    real (kind=dp_t), intent(  out) ::    rhs(lo(1)  :,lo(2)  :,lo(3)  :)  
    real (kind=dp_t), intent(in   ) :: rhs_cc(lo(1)-1:,lo(2)-1:,lo(3)-1:)  
    
    ! Local variables
    integer :: i, j,k
    
    do k = lo(3), hi(3)+1
       do j = lo(2), hi(2)+1
          do i = lo(1), hi(1)+1
             rhs(i,j,k) = EIGHTH * ( rhs_cc(i,j  ,k-1) + rhs_cc(i-1,j  ,k-1) &
                  +rhs_cc(i,j-1,k-1) + rhs_cc(i-1,j-1,k-1) &
                  +rhs_cc(i,j  ,k  ) + rhs_cc(i-1,j  ,k  ) &
                  +rhs_cc(i,j-1,k  ) + rhs_cc(i-1,j-1,k  ) )
          enddo
       enddo
    enddo
    
  end subroutine make_hgrhs_3d
  
end module hgrhs_module
