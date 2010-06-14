module fciqmc

! Module for performing optimised (hopefully!) full configuration interaction
! quantum monte carlo (FCIQMC) calculations.

use fciqmc_data
implicit none

contains

    subroutine init_fciqmc()

        ! Initialisation for fciqmc calculations.
        ! Setup the spin polarisation for the system, initialise the RNG,
        ! allocate the required memory for the list of walkers and set the
        ! initial walker.

        use errors, only: stop_all
        use hashing, only: murmurhash_bit_string
        use parallel, only: iproc, nprocs, parent
        use utils, only: int_fmt

        use basis, only: basis_length
        use calc, only: sym_in, ms_in
        use determinants, only: encode_det, set_spin_polarisation, write_det
        use hamiltonian, only: get_hmatel_real, slater_condon0_hub_real, slater_condon0_hub_k
        use fciqmc_restart, only: read_restart
        use system, only: nel, system_type, hub_real, hub_k

        integer :: ierr
        integer :: i, iproc_ref
        integer :: step

        if (parent) write (6,'(1X,a6,/,1X,6("-"),/)') 'FCIQMC'

        ! Allocate main walker lists.
        allocate(walker_dets(basis_length,walker_length), stat=ierr)
        allocate(walker_population(walker_length), stat=ierr)
        allocate(walker_energies(walker_length), stat=ierr)

        ! Allocate spawned walker lists.
        if (initiator) then
            spawned_size = basis_length + 2
        else
            spawned_size = basis_length + 1
        end if
        if (mod(spawned_walker_length, nprocs) /= 0) then
            write (6,'(1X,a68)') 'spawned_walker_length is not a multiple of the number of processors.'
            spawned_walker_length = ceiling(real(spawned_walker_length)/nprocs)*nprocs
            write (6,'(1X,a35,'//int_fmt(spawned_walker_length,1)//',1X,a1,/)') &
                                        'Increasing spawned_walker_length to',spawned_walker_length,'.'
        end if
        allocate(spawned_walkers1(spawned_size,spawned_walker_length), stat=ierr)
        spawned_walkers => spawned_walkers1
        ! Allocate scratch space for doing communication.
        allocate(spawned_walkers2(spawned_size,spawned_walker_length), stat=ierr)
        spawned_walkers_recvd => spawned_walkers2

        ! Set spawning_head to be the same size as spawning_block_start.
        allocate(spawning_head(0:max(1,nprocs-1)), stat=ierr)

        ! Find the start position within the spawned walker lists for each
        ! processor.
        ! spawning_block_start(1) should contain the number of elements allocated
        ! for each processor so we allow it to be accessible even if the number
        ! of processors is 1.
        allocate(spawning_block_start(0:max(1,nprocs-1)), stat=ierr)
        step = spawned_walker_length/nprocs
        forall (i=0:nprocs-1) spawning_block_start(i) = i*step

        ! Set spin variables.
        call set_spin_polarisation(ms_in)

        ! Set initial walker population.
        ! occ_list could be set and allocated in the input.
        allocate(f0(basis_length), stat=ierr)
        if (restart) then
            if (.not.allocated(occ_list0)) allocate(occ_list0(nel), stat=ierr)
            call read_restart()
        else
            tot_walkers = 1
            walker_population(tot_walkers) = D0_population

            ! Reference det
            ! Set the reference determinant to be the spin-orbitals with the lowest
            ! kinetic energy which satisfy the spin polarisation.
            ! Note: this is for testing only!  The symmetry input is currently
            ! ignored.
            call set_reference_det()

            call encode_det(occ_list0, walker_dets(:,tot_walkers))

            walker_energies(tot_walkers) = 0.0_p

            f0 = walker_dets(:,tot_walkers)
            ! Energy of reference determinant.
            select case(system_type)
            case(hub_k)
                H00 = slater_condon0_hub_k(f0)
            case(hub_real)
                H00 = slater_condon0_hub_real(f0)
            end select

            ! Finally, we need to check if the reference determinant actually
            ! belongs on this processor.
            ! If it doesn't, set the walkers array to be empty.
            if (nprocs > 1) then
                iproc_ref = modulo(murmurhash_bit_string(f0, basis_length), nprocs)
                if (iproc_ref /= iproc) tot_walkers = 0
                D0_proc = iproc_ref
            else
                D0_proc = iproc
            end if
        end if

        ! Total number of particles on processor.
        ! Probably should be handled more simply by setting it to be either 0 or
        ! D0_population or obtaining it from the restart file, as appropriate.
        nparticles = sum(abs(walker_population(:tot_walkers)))

        if (parent) then
            write (6,'(1X,a29,1X)',advance='no') 'Reference determinant, |D0> ='
            call write_det(f0, new_line=.true.)
            write (6,'(1X,a16,f20.12)') 'E0 = <D0|H|D0> =',H00
            write (6,'(1X,a44,'//int_fmt(D0_population,1)//',/)') &
                              'Initial population on reference determinant:',D0_population
            write (6,'(1X,a68,/)') 'Note that FCIQMC calculates the correlation energy relative to |D0>.'
            if (initiator) then
                write (6,'(1X,a24)') 'Initiator method in use.'
                write (6,'(1X,a36,1X,"(",'//int_fmt(CAS(1),0)//',",",'//int_fmt(CAS(2),0)//'")")')  &
                    'CAS space of initiator determinants:',CAS
                write (6,'(1X,a66,'//int_fmt(initiator_population,1)//',/)') &
                    'Population for a determinant outside CAS space to be an initiator:', initiator_population
            end if
            write (6,'(1X,a49,/)') 'Information printed out every FCIQMC report loop:'
            write (6,'(1X,a66)') 'Instant shift: the shift calculated at the end of the report loop.'
            write (6,'(1X,a88)') 'Average shift: the running average of the shift from when the shift was allowed to vary.'
            write (6,'(1X,a98)') 'Proj. Energy: projected energy averaged over the report loop. &
                                 &Calculated at the end of each cycle.'
            write (6,'(1X,a53)') 'Av. Proj. E: running average of the projected energy.'
            write (6,'(1X,a54)') '# D0: current population at the reference determinant.'
            write (6,'(1X,a49)') '# particles: current total population of walkers.'
            write (6,'(1X,a56,/)') 'R_spawn: average rate of spawning across all processors.'
        end if
        
    end subroutine init_fciqmc

    subroutine fciqmc_main()

        ! Wrapper around do_fciqmc and do_ifciqmc to set the appropriate procedures
        ! that are to be called for the current fciqmc calculation.
        ! This is a bit hacky, but avoids lots of branching due to if blocks
        ! within the fciqmc algorithm.

        use system, only: system_type, hub_k, hub_real
        use hamiltonian, only: slater_condon0_hub_k, slater_condon0_hub_real
        use determinants, only: decode_det_spinocc_spinunocc, decode_det_occ
        use energy_evaluation, only: update_proj_energy_hub_k, update_proj_energy_hub_real
        use spawning, only: spawn_hub_k, spawn_hub_real

        if (initiator) then
            select case(system_type)
            case(hub_k)
                call do_ifciqmc(decode_det_spinocc_spinunocc, update_proj_energy_hub_k, spawn_hub_k, slater_condon0_hub_k)
            case(hub_real)
                call do_ifciqmc(decode_det_occ, update_proj_energy_hub_real, spawn_hub_real, slater_condon0_hub_real)
            end select
        else
            select case(system_type)
            case(hub_k)
                call do_fciqmc(decode_det_spinocc_spinunocc, update_proj_energy_hub_k, spawn_hub_k, slater_condon0_hub_k)
            case(hub_real)
                call do_fciqmc(decode_det_occ, update_proj_energy_hub_real, spawn_hub_real, slater_condon0_hub_real)
            end select
        end if

    end subroutine fciqmc_main

    subroutine do_fciqmc(decoder, update_proj_energy, spawner, sc0)

        ! Run the FCIQMC algorithm starting from the initial walker
        ! distribution.

        ! This is implemented by abusing fortran's ability to pass procedures as
        ! arguments (if only function pointers (F2003) were implemented in more
        ! compilers!).  This allows us to avoid many system dependent if blocks,
        ! which are constant for a given calculation.  Avoiding such branching
        ! is worth the extra verbosity (especially if procedures are written to
        ! be sufficiently modular that implementing a new system can reuse many
        ! existing routines) as it leads to much faster code.

        ! (This idea is now being "borrowed" for use in neci.  Bah...)

        ! In:
        !    decoder: relevant subroutine to decode/extract the necessary
        !        information from the determinant bit string.  See the
        !        determinants module.
        !    update_proj_energy: relevant subroutine to update the projected
        !        energy.  See the energy_evaluation module.
        !    spawner: relevant subroutine to attempt to spawn a walker from an
        !        existing walker.  See the spawning module.
        !    sc0: relevant function to evaluate the diagonal Hamiltonian matrix
        !    elements, <D|H|D>.  See the hamiltonian module.

        use parallel
  
        use annihilation, only: direct_annihilation
        use basis, only: basis_length
        use death, only: stochastic_death
        use determinants, only:det_info, alloc_det_info 
        use energy_evaluation, only: update_energy_estimators
        use excitations, only: excit
        use interact, only: fciqmc_interact
        use fciqmc_restart, only: dump_restart
        use spawning, only: create_spawned_particle
        use fciqmc_common

        ! It seems this interface block cannot go in a module when we're passing
        ! subroutines around as arguments.  Bummer.
        ! If only procedure pointers were more commonly implemented...
        interface
            subroutine decoder(f,d)
                use basis, only: basis_length
                use const, only: i0
                use determinants, only: det_info
                implicit none
                integer(i0), intent(in) :: f(basis_length)
                type(det_info), intent(inout) :: d
            end subroutine decoder
            subroutine update_proj_energy(idet, inst_proj_energy)
                use const, only: p
                implicit none
                integer, intent(in) :: idet
                real(p), intent(inout) :: inst_proj_energy
            end subroutine update_proj_energy
            subroutine spawner(d, parent_sign, nspawned, connection)
                use determinants, only: det_info
                use excitations, only: excit
                implicit none
                type(det_info), intent(in) :: d
                integer, intent(in) :: parent_sign
                integer, intent(out) :: nspawned
                type(excit), intent(out) :: connection
            end subroutine spawner
            function sc0(f) result(hmatel)
                use basis, only: basis_length
                use const, only: i0, p
                implicit none
                real(p) :: hmatel
                integer(i0), intent(in) :: f(basis_length)
            end function sc0
        end interface

        integer :: idet, ireport, icycle, iparticle, nparticles_old
        type(det_info) :: cdet

        integer :: nspawned, nattempts
        type(excit) :: connection

        real(p) :: inst_proj_energy

        logical :: soft_exit

        real :: t1, t2

        ! Allocate det_info components.
        call alloc_det_info(cdet)

        ! from restart
        nparticles_old = nparticles_old_restart

        ! Main fciqmc loop.

        if (parent) call write_fciqmc_report_header()
        call initial_fciqmc_status(update_proj_energy)

        ! Initialise timer.
        call cpu_time(t1)

        do ireport = 1, nreport

            ! Zero report cycle quantities.
            proj_energy = 0.0_p
            rspawn = 0.0_p

            do icycle = 1, ncycles

                ! Zero MC cycle quantities.
                inst_proj_energy = 0.0_p
                D0_population = 0

                ! Reset the current position in the spawning array to be the
                ! slot preceding the first slot.
                spawning_head = spawning_block_start

                ! Number of spawning attempts that will be made.
                nattempts = nparticles

                do idet = 1, tot_walkers ! loop over walkers/dets

                    cdet%f = walker_dets(:,idet)

                    call decoder(cdet%f, cdet)

                    ! It is much easier to evaluate the projected energy at the
                    ! start of the FCIQMC cycle than at the end, as we're
                    ! already looping over the determinants.
                    call update_proj_energy(idet, inst_proj_energy)

                    do iparticle = 1, abs(walker_population(idet))
                        
                        ! Attempt to spawn.
                        call spawner(cdet, walker_population(idet), nspawned, connection)
                        ! Spawn if attempt was successful.
                        if (nspawned /= 0) call create_spawned_particle(cdet, connection, nspawned)

                    end do

                    ! Clone or die.
                    call stochastic_death(idet)

                end do

                ! Add the spawning rate (for the processor) to the running
                ! total.
                rspawn = rspawn + spawning_rate(nattempts)

                ! D0_population is communicated in the direct_annihilation
                ! algorithm for efficiency.
                call direct_annihilation(sc0)

                ! normalise projected energy and add to running total.
                proj_energy = proj_energy + inst_proj_energy/D0_population

            end do

            ! Update the energy estimators (shift & projected energy).
            call update_energy_estimators(ireport, nparticles_old)

            call cpu_time(t2)

            ! t1 was the time at the previous iteration, t2 the current time.
            ! t2-t1 is thus the time taken by this report loop.
            if (parent) call write_fciqmc_report(ireport, nparticles_old, t2-t1)

            ! cpu_time outputs an elapsed time, so update the reference timer.
            t1 = t2

            call fciqmc_interact(ireport, soft_exit)
            if (soft_exit) exit

        end do

        if (parent) then
            call write_fciqmc_final(ireport)
            write (6,'()')
        end if

        call load_balancing_report()

        if (dump_restart_file) call dump_restart(mc_cycles_done+ncycles*nreport, nparticles_old)

    end subroutine do_fciqmc

    subroutine do_ifciqmc(decoder, update_proj_energy, spawner, sc0)

        ! Run the initiator-FCIQMC algorithm starting from the initial walker
        ! distribution.

        ! See notes about the implementation of this using function pointers
        ! (F77 style rather than F2003, sadly!) in do_fciqmc.

        ! In:
        !    decoder: relevant subroutine to decode/extract the necessary
        !        information from the determinant bit string.  See the
        !        determinants module.
        !    update_proj_energy: relevant subroutine to update the projected
        !        energy.  See the energy_evaluation module.
        !    spawner: relevant subroutine to attempt to spawn a walker from an
        !        existing walker.  See the spawning module.
        !    sc0: relevant function to evaluate the diagonal Hamiltonian matrix
        !    elements, <D|H|D>.  See the hamiltonian module.

        use parallel
  
        use annihilation, only: direct_annihilation_initiator
        use basis, only: basis_length, bit_lookup, nbasis
        use death, only: stochastic_death
        use determinants, only: det_info, alloc_det_info
        use energy_evaluation, only: update_energy_estimators
        use excitations, only: excit
        use interact, only: fciqmc_interact
        use fciqmc_restart, only: dump_restart
        use system, only: nel
        use spawning, only: create_spawned_particle_initiator
        use fciqmc_common

        ! It seems this interface block cannot go in a module when we're passing
        ! subroutines around as arguments.  Bummer.
        ! If only procedure pointers were more commonly implemented...
        interface
            subroutine decoder(f,d)
                use basis, only: basis_length
                use const, only: i0
                use determinants, only: det_info
                implicit none
                integer(i0), intent(in) :: f(basis_length)
                type(det_info), intent(inout) :: d
            end subroutine decoder
            subroutine update_proj_energy(idet, inst_proj_energy)
                use const, only: p
                implicit none
                integer, intent(in) :: idet
                real(p), intent(inout) :: inst_proj_energy
            end subroutine update_proj_energy
            subroutine spawner(d, parent_sign, nspawned, connection)
                use determinants, only: det_info
                use excitations, only: excit
                implicit none
                type(det_info), intent(in) :: d
                integer, intent(in) :: parent_sign
                integer, intent(out) :: nspawned
                type(excit), intent(out) :: connection
            end subroutine spawner
            function sc0(f) result(hmatel)
                use basis, only: basis_length
                use const, only: i0, p
                implicit none
                real(p) :: hmatel
                integer(i0), intent(in) :: f(basis_length)
            end function sc0
        end interface

        integer :: i, idet, ireport, icycle, iparticle, nparticles_old
        type(det_info) :: cdet

        integer :: nspawned, nattempts
        type(excit) :: connection

        real(p) :: inst_proj_energy

        integer :: parent_flag
        integer(i0) :: cas_mask(basis_length), cas_core(basis_length)
        integer :: bit_pos, bit_element

        logical :: soft_exit

        real :: t1, t2

        ! Allocate det_info components.
        call alloc_det_info(cdet)

        ! The complete active space (CAS) is given as (N_cas,N_active), where
        ! N_cas is the number of electrons in the N_active orbitals.
        ! The N-N_cas electrons occupy the lowest energy orbitals ("core"
        ! orbitals) for all determinants within the CAS.
        ! The 2M-N_core-N_active highest energy orbitals are inactive and are
        ! not occupied in any determinants within the CAS.
        ! Create a mask which has bits set for all core electrons and a mask
        ! which has bits set for all inactive orbitals.
        cas_mask = 0
        cas_core = 0
        ! Set core obitals.
        do i = 1, nel - CAS(1)
            bit_pos = bit_lookup(1,i)
            bit_element = bit_lookup(2,i)
            cas_mask = ibset(cas_mask(bit_element), bit_pos)
            cas_core = ibset(cas_core(bit_element), bit_pos)
        end do
        ! Set inactive obitals.
        do i = nel - CAS(1) + 2*CAS(2) + 1, nbasis
            bit_pos = bit_lookup(1,i)
            bit_element = bit_lookup(2,i)
            cas_mask = ibset(cas_mask(bit_element), bit_pos)
        end do
        ! Thus ANDing a determinant with cas_mask gives the electrons in the
        ! core or inactive orbitals.  The determinant is only in the CAS if the
        ! result is identical to the cas_core mask (i.e. all the core orbitals
        ! are filled and no electrons are in the inactive orbitals).

        ! from restart
        nparticles_old = nparticles_old_restart

        ! Main fciqmc loop.

        if (parent) call write_fciqmc_report_header()
        call initial_fciqmc_status(update_proj_energy)

        ! Initialise timer.
        call cpu_time(t1)

        do ireport = 1, nreport

            ! Zero report cycle quantities.
            proj_energy = 0.0_p
            rspawn = 0.0_p

            do icycle = 1, ncycles

                ! Zero MC cycle quantities.
                inst_proj_energy = 0.0_p
                D0_population = 0

                ! Reset the current position in the spawning array to be the
                ! slot preceding the first slot.
                spawning_head = spawning_block_start

                ! Number of spawning attempts that will be made.
                nattempts = nparticles

                do idet = 1, tot_walkers ! loop over walkers/dets

                    cdet%f = walker_dets(:,idet)

                    call decoder(cdet%f, cdet)

                    ! It is much easier to evaluate the projected energy at the
                    ! start of the i-FCIQMC cycle than at the end, as we're
                    ! already looping over the determinants.
                    call update_proj_energy(idet, inst_proj_energy)

                    ! Is this determinant an initiator?
                    if (abs(walker_population(idet)) > initiator_population) then
                        ! Has a high enough population to be an initiator.
                        parent_flag = 0
                    else if (all(iand(cdet%f,cas_mask) == cas_core)) then
                        ! Is in the complete active space.
                        parent_flag = 0
                    else
                        ! Isn't an initiator.
                        parent_flag = 1
                    end if

                    do iparticle = 1, abs(walker_population(idet))
                        
                        ! Attempt to spawn.
                        call spawner(cdet, walker_population(idet), nspawned, connection)
                        ! Spawn if attempt was successful.
                        if (nspawned /= 0) call create_spawned_particle_initiator(cdet, parent_flag, connection, nspawned)

                    end do

                    ! Clone or die.
                    call stochastic_death(idet)

                end do

                ! Add the spawning rate (for the processor) to the running
                ! total.
                rspawn = rspawn + spawning_rate(nattempts)

                ! D0_population is communicated in the direct_annihilation
                ! algorithm for efficiency.
                call direct_annihilation_initiator(sc0)

                ! normalise projected energy and add to running total.
                proj_energy = proj_energy + inst_proj_energy/D0_population

            end do

            ! Update the energy estimators (shift & projected energy).
            call update_energy_estimators(ireport, nparticles_old)

            call cpu_time(t2)

            ! t1 was the time at the previous iteration, t2 the current time.
            ! t2-t1 is thus the time taken by this report loop.
            if (parent) call write_fciqmc_report(ireport, nparticles_old, t2-t1)

            ! cpu_time outputs an elapsed time, so update the reference timer.
            t1 = t2

            call fciqmc_interact(ireport, soft_exit)
            if (soft_exit) exit

        end do

        if (parent) then
            call write_fciqmc_final(ireport)
            write (6,'()')
        end if

        call load_balancing_report()

        if (dump_restart_file) call dump_restart(mc_cycles_done+ncycles*nreport, nparticles_old)

    end subroutine do_ifciqmc

end module fciqmc