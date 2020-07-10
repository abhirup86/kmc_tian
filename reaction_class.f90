module reaction_class

  use constants
  use control_parameters_class
  use mc_lat_class
  use energy_parameters_class
  use energy_mod
  use open_file
  use utilities
  use rates_hopping_class
  use rates_desorption_class
  use rates_dissociation_class

  implicit none

  private
  public    :: reaction_init, reaction_type


  type :: reaction_type

    type(     hopping_type) :: hopping
    type(  desorption_type) :: desorption
    type(dissociation_type) :: dissociation

    real(dp) :: beta                    ! inverse thermodynamic temperature
    integer  :: n_ads_total             ! total number of adsorbates
    real(dp) :: total_rate              ! sum over all relevant rates

  contains
    procedure :: construct
    procedure :: do_reaction

  end type


contains
!-------------------------------------1-----------------------------------------
  function reaction_init(c_pars, lat, e_pars)
!------------------------------------------------------------------------------
    type(reaction_type) reaction_init

    type(control_parameters), intent(in)    :: c_pars ! Warning: check where c_pars gets redefined
    type(mc_lat)            , intent(in)    :: lat
    type(energy_parameters) , intent(in)    :: e_pars


    ! Create a rate structure
    reaction_init%hopping      =      hopping_init(c_pars, lat, e_pars)
    reaction_init%desorption   =   desorption_init(c_pars, lat, e_pars)
    reaction_init%dissociation = dissociation_init(c_pars, lat, e_pars)
!    call reaction_init%hopping%print(c_pars)
!    call reaction_init%desorption%print(c_pars)
    call reaction_init%dissociation%print(c_pars)

    reaction_init%beta = 1.0_dp/(kB*c_pars%temperature)
    reaction_init%n_ads_total = lat%n_ads_tot()

  end function reaction_init

!-----------------------------------------------------------------------------
  subroutine construct(this, lat, e_pars)
!-----------------------------------------------------------------------------
    class(reaction_type),     intent(inout) :: this
    class(mc_lat),            intent(inout) :: lat
    class(energy_parameters), intent(in)    :: e_pars

    integer :: i,m

    ! Hopping
    if (this%hopping%is_defined) then
      do i=1,this%n_ads_total
        call this%hopping%construct(i, lat, e_pars, this%beta)
      end do
    end if

    ! Desorption
    if (this%desorption%is_defined) then
      do i=1,this%n_ads_total
        call this%desorption%construct(i, lat, e_pars, this%beta)
      end do
    end if

    ! Dissociation
    print*
    call lat%print_ocs
    print*,'Dissociation rates:'
    print*
    if (this%dissociation%is_defined) then
      do i=1,this%n_ads_total
        call this%dissociation%construct(i, lat, e_pars, this%beta)

        write(*,'(A,i4,A,i4,X,A,A)') 'ads: ',i, ' reactant: ', lat%ads_list(i)%id, site_names(lat%lst(lat%ads_list(i)%row,lat%ads_list(i)%col)), ads_site_names(lat%ads_list(i)%ast)
        do m=1,lat%n_nn(1)
          write(*,'(A,i4,A,10f4.1)') 'Direction: ',m, " Rates: ", this%dissociation%rates(i,m)%list
        end do

      end do
    end if
stop 555
  end subroutine construct

!-----------------------------------------------------------------------------
  subroutine do_reaction(this, rand, lat, e_pars)
!-----------------------------------------------------------------------------
    class(reaction_type), intent(inout)     :: this
    real(dp),             intent(in)        :: rand
    class(mc_lat),        intent(inout)     :: lat
    class(energy_parameters), intent(in)    :: e_pars

    integer :: i, m, ads, iads, reaction_id, i_change
    integer :: n_nn, n_nn2, m_nn
    integer :: row, col, row_new, col_new, lst_new, ast_new, id
    real(dp), dimension(n_reaction_types) :: acc_rate
    integer, dimension(2*lat%n_nn(1)) :: change_list

    real(dp) :: u, temp_dp

    n_nn  = lat%n_nn(1)
    n_nn2 = n_nn/2

    ! -------- calculate total rate

    ! initialize the accumulated rate for hopping
    acc_rate(hopping_id) = 0.0_dp
    ! rate for hopping reactions
    if (this%hopping%is_defined) then
      do ads=1,this%n_ads_total
      do m=1,n_nn
        acc_rate(hopping_id) = acc_rate(hopping_id) + sum(this%hopping%rates(ads,m)%list)
      end do
      end do
    end if
    ! accumulate rate for desorption (= rate for desorption reactions + hopping reactions)
    acc_rate(desorption_id) = acc_rate(hopping_id)
    if (this%desorption%is_defined) then
      do ads=1,this%n_ads_total
        acc_rate(desorption_id) = acc_rate(desorption_id) + this%desorption%rates(ads)
      end do
    end if

    acc_rate(dissociation_id) = acc_rate(hopping_id)
    ! Save the total rate value
    this%total_rate = acc_rate(n_reaction_types)
    ! do nothing if there is nothing to do
    if (this%total_rate == 0.0_dp) return

    ! ------- Select the process

    ! random rate value to select a process
    u = rand*this%total_rate
    ! determine the type of reaction
    do reaction_id=1,n_reaction_types
      if (u < acc_rate(reaction_id)) exit
    end do

    select case (reaction_id)

      case(hopping_id)
        ! determine hopping channel (adsorbate, direction, ads. site of available ones)
        !                           (      ads,      m_nn,                        iads)
        temp_dp = 0.0_dp
        extloop: do ads=1,this%n_ads_total
          do m_nn=1,n_nn
          do iads=1,size(this%hopping%rates(ads,m_nn)%list) ! Warning: check timing of size calculation
            temp_dp = temp_dp + this%hopping%rates(ads,m_nn)%list(iads)
            if (u < temp_dp) exit extloop
          end do
          end do
        end do extloop

        ! Update hopping rate constants
        ! Particle (ads) is going to hop in direction (m_nn) to ads. site (iads)

        ! create a list of adsorbates affected by hop

        change_list = 0
        i_change = 1
        ! Put the hopping particle iads into the list
        change_list(i_change) = ads

        ! scan over old neighbors
        do m=1,n_nn
          ! position of neighbor m
          call lat%neighbor(ads,m,row,col)
          if (lat%occupations(row,col) > 0) then
            i_change = i_change + 1
            change_list(i_change) = lat%occupations(row,col)
          end if
        end do

        ! a new position of particle (ads) after a hop to a neighbor (m_nn)
        call lat%neighbor(ads,m_nn,row_new,col_new)
        id = lat%ads_list(ads)%id
        lst_new = lat%lst(row_new,col_new)
        ast_new = lat%avail_ads_sites(id,lst_new)%list(iads)

        ! Make a hop:
        ! Delete an adsorbate from its old position
        lat%occupations(lat%ads_list(ads)%row, lat%ads_list(ads)%col) = 0
        ! Put the adsorbate in a new position
        lat%ads_list(ads)%row  = row_new
        lat%ads_list(ads)%col  = col_new
        lat%ads_list(ads)%ast  = ast_new
        ! Update adsorbate position
        lat%occupations(row_new, col_new) = ads

        ! scan over additional new neighbors
        do m=1,n_nn2
          ! position of neighbor nn_new(m_nn,m)
          call lat%neighbor( ads, this%hopping%nn_new(m_nn,m), row, col)
          if (lat%occupations(row,col) > 0) then
            i_change = i_change + 1
            change_list(i_change) = lat%occupations(row,col)
          end if
        end do

        ! Update rate array for the affected adsorbates

        do i=1,i_change
          call this%hopping%construct(change_list(i), lat, e_pars, this%beta)
        end do

      case(desorption_id)
        ! determine desorption channel (adsorbate)
        !                              (      ads)
        temp_dp = acc_rate(hopping_id)
        do ads=1,this%n_ads_total
          temp_dp = temp_dp + this%desorption%rates(ads)
          if (u < temp_dp) exit
        end do

        ! Update desorption rate constants
        ! Particle (ads) is going to desorb to nowhere

        ! create a list of adsorbates affected by desorption
        change_list = 0
        i_change = 0

        ! scan over neighbors
        do m=1,n_nn
          ! position of neighbor m
          call lat%neighbor(ads,m,row,col)
          if (lat%occupations(row,col) > 0) then
            i_change = i_change + 1
            change_list(i_change) = lat%occupations(row,col)
          end if
        end do

        ! Do desorption:
        ! Delete an adsorbate from the lattice
        lat%occupations(lat%ads_list(ads)%row, lat%ads_list(ads)%col) = 0
        ! Update the number of adsorbates in the lat structure
        lat%n_ads(lat%ads_list(ads)%id) = lat%n_ads(lat%ads_list(ads)%id) - 1
        ! Rearrange adsorbates except when the last adsorbate desorbs
        if (ads < this%n_ads_total) then
          ! Put the last adsorbate in place of ads
          lat%ads_list(ads) = lat%ads_list(this%n_ads_total)
          ! Update the adsorbate number in the lattice
          lat%occupations(lat%ads_list(ads)%row, lat%ads_list(ads)%col) = ads
        end if

        ! Update rate array for the affected adsorbates
        do i=1,i_change
          ! account for the tightening the ads. list
          if (change_list(i) == this%n_ads_total) change_list(i) = ads
          call this%desorption%construct(change_list(i), lat, e_pars, this%beta)
        end do

        ! Adjust the rates arrays except when ads is the last particle
        if (ads < this%n_ads_total) then
          this%desorption%rates(ads) = this%desorption%rates(this%n_ads_total)
          this%hopping%rates(ads,:)  = this%hopping%rates(this%n_ads_total,:)
        end if

        ! Update the the number of adsorbates in this
        this%n_ads_total = this%n_ads_total - 1

      case default
        print*
        print*, "reaction id is ", reaction_id
        print*, "number of reactions is ", n_reaction_types
        stop 'do_reaction (of reaction_class): must never occur!'

    end select

  end subroutine do_reaction

end module reaction_class