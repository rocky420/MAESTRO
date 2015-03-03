! DO NOT EDIT THIS FILE!!!
!
! This file is automatically generated by write_probin.py at
! compile-time.
!
! To add a runtime parameter, do so by editting the appropriate _parameters
! file.

! This module stores the runtime parameters.  The probin_init() routine is
! used to initialize the runtime parameters

! this version is a stub -- useful for when we only need a container for 
! parameters, but not for MAESTRO use.

module probin_module

  use bl_types

  implicit none

  private

  integer, save, public :: a_dummy_var = 0


end module probin_module


module extern_probin_module

  use bl_types

  implicit none

  private

  logical, save, public :: use_eos_coulomb = .true.

end module extern_probin_module


module runtime_init_module

  use bl_types
  use probin_module
  use extern_probin_module

  implicit none

  namelist /probin/ use_eos_coulomb

  private

  public :: probin

  public :: runtime_init, runtime_close

contains

  subroutine runtime_init()

    
  end subroutine runtime_init

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  subroutine runtime_close()

    use probin_module

  end subroutine runtime_close

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

end module runtime_init_module
