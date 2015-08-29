var/list/pod_list = list()

/obj/pod
	name = "Pod"
	icon = 'icons/obj/pod-1-1.dmi'
	icon_state = "miniputt"
	density = 1
	anchored = 1
	layer = 3.2

	var/list/size = list(1, 1)
	var/obj/machinery/portable_atmospherics/canister/internal_canister
	var/datum/gas_mixture/internal_air
	var/obj/item/weapon/stock_parts/cell/power_source
	var/inertial_direction = NORTH
	var/turn_direction = NORTH
	var/last_move_time = 0
	var/move_cooldown = 2
	var/enter_delay = 10
	var/exit_delay = 10
	var/movement_cost = 2
	var/list/locks = list() // DNA (unique_enzymes) or code lock.
	var/lumens = 6
	var/toggles = 0
	var/seats = 0 // Amount of additional people that can fit into the pod (excludes pilot)
	var/being_repaired = 0

	var/list/hardpoints = list()
	var/list/attachments = list()

	var/datum/global_iterator/pod_inertial_drift/inertial_drift_iterator
	var/datum/global_iterator/pod_equalize_air/equalize_air_iterator
	var/datum/global_iterator/pod_attachment_processor/process_attachments_iterator
	var/datum/global_iterator/pod_damage/pod_damage_iterator

	var/mob/living/carbon/human/pilot = 0

	var/datum/effect/effect/system/spark_spread/sparks

	var/datum/pod_log/pod_log

	New()
		..()

		if(!size || !size.len)
			qdel(src)
			return

		pod_list += src

		bound_width = size[1] * 32
		bound_height = size[2] * 32

		internal_canister = GetCanister()
		internal_air = GetEnvironment()
		hardpoints = GetHardpoints()
		power_source = GetPowercell()
		attachments = (GetAdditionalAttachments() + GetArmor() + GetEngine())
		seats = GetSeats()
		pod_log = new(src)

		// Should be fine if we initialize a global variable in here.
		if(!pod_config)
			pod_config = new()

		spawn(0)
			inertial_drift_iterator = new(list(src))
			equalize_air_iterator = new(list(src))
			process_attachments_iterator = new(list(src))
			pod_damage_iterator = new(list(src))

		max_health = initial(health)

		sparks = new /datum/effect/effect/system/spark_spread()
		sparks.set_up(5, 0, src)
		sparks.attach(src)

		if(fexists("icons/obj/pod-[size[1]]-[size[2]].dmi"))
			icon = file("icons/obj/pod-[size[1]]-[size[2]].dmi")

		// Place attachments / batteries under the pod and they'll get attached (map editor)
		spawn(10)
			for(var/turf/T in GetTurfsUnderPod())
				for(var/obj/item/weapon/pod_attachment/P in T)
					if(CanAttach(P))
						P.OnAttach(src, 0)

				var/obj/item/weapon/stock_parts/cell/cell = locate() in T
				if(cell)
					qdel(power_source)
					cell.loc = src
					power_source = cell

	Del()
		DestroyPod()
		..()

	examine()
		..()
		var/hp = HealthPercent()
		switch(hp)
			if(-INFINITY to 25)
				usr << "<span class='warning'>It looks severely damaged.</span>"
			if(26 to 50)
				usr << "<span class='warning'>It looks significantly damaged.</span>"
			if(51 to 75)
				usr << "<span class='warning'>It looks moderately damaged.</span>"
			if(76 to 99)
				usr << "<span class='warning'>It looks slightly damaged.</span>"
			if(100 to INFINITY)
				usr << "<span class='info'>It looks undamaged.</span>"

		usr << "<span class='info'>Attached are:</span>"
		for(var/obj/item/weapon/pod_attachment/attachment in GetAttachments())
			if(attachment.hardpoint_slot in list(P_HARDPOINT_PRIMARY_ATTACHMENT, P_HARDPOINT_ARMOR, P_HARDPOINT_SHIELD, P_HARDPOINT_SECONDARY_ATTACHMENT))
				usr << "<span class='info'>- \The [attachment.name]"

	update_icon()
		overlays.Cut()

		for(var/obj/item/weapon/pod_attachment/A in attachments)
			var/image/overlay = A.GetOverlay(size)
			if(!overlay)	continue
			overlays += overlay

		if(HasDamageFlag(P_DAMAGE_GENERAL))
			overlays += image(icon = "icons/obj/pod-[size[1]]-[size[2]].dmi", icon_state = "pod_damage")

		if(HasDamageFlag(P_DAMAGE_FIRE))
			overlays += image(icon = "icons/obj/pod-[size[1]]-[size[2]].dmi", icon_state = "pod_fire")

	proc/HandleExit(var/mob/living/carbon/human/H)
		if(toggles & P_TOGGLE_HUDLOCK)
			if(alert(H, "Outside HUD Access is diabled, are you sure you want to exit?", "Confirmation", "Yes", "No") == "No")
				return 0

		var/as_pilot = (H == pilot)

		H << "<span class='info'>You start leaving the [src]..<span>"
		if(do_after(H, exit_delay))
			H << "<span class='info'>You leave the [src].</span>"
			H.loc = get_turf(src)
			if(as_pilot)
				pilot = 0

		pod_log.LogOccupancy(H, as_pilot)

	proc/HandleEnter(var/mob/living/carbon/human/H)
		if(!CanOpenPod(H))
			return 0

		var/as_passenger = 0
		if(pilot)
			if(HasOpenSeat())
				var/enter_anyways = input("The [src] is already manned. Do you want to enter as a passenger?") in list("Yes", "No")
				if(enter_anyways == "Yes")
					as_passenger = 1
				else
					return 0
			else
				H << "<span class='warning'>The [src] is already manned[seats ? " and all the seats are occupied" : ""]."
				return 0

		H << "<span class='info'>You start to enter the [src]..</span>"
		if(do_after(H, enter_delay))
			H << "<span class='info'>You enter the [src].</span>"
			H.loc = src
			if(!as_passenger)
				pilot = H
				PrintSystemNotice("Systems initialized.")
				if(power_source)
					PrintSystemNotice("Power Charge: [power_source.charge]/[power_source.maxcharge] ([power_source.percent()]%)")
				else
					PrintSystemAlert("No power source installed.")
				PrintSystemNotice("Integrity: [round((health / max_health) * 100)]%.")

		pod_log.LogOccupancy(H, !as_passenger)

	MouseDrop_T(var/atom/dropping, var/mob/user)
		if(istype(dropping, /mob/living/carbon/human))
			if(dropping == user)
				HandleEnter(dropping)

	relaymove(var/mob/user, var/_dir)
		if(user == pilot)
			DoMove(user, _dir)

	proc/DoMove(var/mob/user, var/_dir)
		if(user != pilot)
			return 0

		var/obj/item/weapon/pod_attachment/engine/engine = GetAttachmentOnHardpoint(P_HARDPOINT_ENGINE)
		if(!engine)
			PrintSystemAlert("No engine attached.")
			return 0
		else if(engine.active & P_ATTACHMENT_INACTIVE)
			PrintSystemAlert("Engine is turned off.")
			return 0

		if(!HasPower(movement_cost))
			PrintSystemAlert("Insufficient power.")
			return 0

		if(HasDamageFlag(P_DAMAGE_EMPED))
			_dir = pick(cardinal)

		var/can_drive_over = 0
		var/is_dense = 0
		for(var/turf/T in GetDirectionalTurfs(_dir))
			if(T.density)
				is_dense = 1
			for(var/path in pod_config.drivable)
				if(istext(path))	path = text2path(path)
				if(istype(T, path) || istype(get_area(T), path) || (T.icon_state == "plating"))
					can_drive_over = 1
					break
				else
					if(istype(T, /turf/simulated/floor))
						var/turf/simulated/floor/F = T
						if(F.icon_state == F.icon_plating)
							can_drive_over = 1
							break

		// Bump() does not play nice with 64x64, so this will have to do.
		if(is_dense)
			dir = _dir
			var/list/turfs = GetDirectionalTurfs(dir)
			for(var/obj/item/weapon/pod_attachment/attachment in GetAttachments())
				attachment.PodBumpedAction(turfs)
			last_move_time = world.time
			return 0

		if(!can_drive_over)
			dir = _dir
			last_move_time = world.time
			return 0

		if(size[1] > 1)
			// So for some reason when going north or east, Entered() isn't called on the turfs in a 2x2 pod
			for(var/turf/space/space in GetTurfsUnderPod())
				space.Entered(src)

		if(istype(get_turf(src), /turf/space) && !HasTraction())
			if((_dir == turn(inertial_direction, 180)) && (toggles & P_TOGGLE_SOR))
				inertial_direction = 0
				return 1

			if(turn_direction == _dir)
				inertial_direction = _dir
			else
				dir = _dir
				turn_direction = _dir
		else
			if((last_move_time + move_cooldown) > world.time)
				return 0

			step(src, _dir)
			UsePower(movement_cost)
			turn_direction = _dir
			inertial_direction = _dir

		last_move_time = world.time

	attack_hand(var/mob/living/user)
		if(user.a_intent == "grab")
			if(pilot)
				var/result = input(user, "Do you want to pull the pilot out of the pod?", "Confirmation") in list("Yes", "No")
				if(result == "No")
					return 0
				pilot << "<span class='warning'>You are being pulled out of the pod by [user].</span>"
				user << "<span class='info'>You start to pull out the pilot.</span>"
				if(do_after(user, pod_config.pod_pullout_delay))
					if(pilot)
						pilot << "<span class='warning'>You were pulled out of \the [src] from [user].</span>"
						pod_log.LogOccupancy(pilot, 1, user)
						pilot.loc = get_turf(src)
						pilot = 0

					else return 0
			else
				user << "<span class='info'>\The [src] is unmanned.</span>"

			return 1

		..()

	attackby(var/obj/item/I, var/mob/living/user)
		if(istype(I, /obj/item/weapon/pod_attachment))
			var/obj/item/weapon/pod_attachment/attachment = I

			var/can_attach_result = CanAttach(attachment)
			if(can_attach_result & P_ATTACH_ERROR_CLEAR)
				attachment.StartAttach(src, user)
			else
				switch(can_attach_result)
					if(P_ATTACH_ERROR_TOOBIG)
						user << "<span class='warning'>The [src] is too small for the [I].</span>"
					if(P_ATTACH_ERROR_ALREADY_ATTACHED)
						user << "<span class='warning'>There is already an attachment on that slot.</span>"
				return 0
			return 1

		if(user.a_intent == "harm")
			goto Damage

		if(istype(I, /obj/item/weapon/stock_parts/cell))
			if(power_source)
				user << "<span class='warning'>There is already a cell installed.</span>"
				return 0
			else
				user << "<span class='notice'>You start to install \the [I] into \the [src].</span>"
				if(do_after(user, 20))
					user.unEquip(I, 1)
					I.loc = src
					power_source = I

		if(istype(I, /obj/item/device/multitool))
			if(CanOpenPod(user))
				OpenHUD(user)

			return 1

		if(istype(I, /obj/item/stack/sheet/metal))
			if(being_repaired)
				return 0

			if(HealthPercent() > pod_config.metal_repair_threshold_percent)
				user << "<span class='warning'>\The [src] doesn't require any more metal.</span>"
				return 0

			var/obj/item/stack/sheet/metal/M = I

			being_repaired = 1

			user << "<span class='info'>You start to add metal to \the [src].</span>"
			while(do_after(user, 30) && M && M.amount)
				user << "<span class='info'>You add some metal to \the [src].</span>"
				health += pod_config.metal_repair_amount
				update_icon()
				M.use(1)
				if(HealthPercent() > pod_config.metal_repair_threshold_percent)
					user << "<span class='warning'>\The [src] doesn't require any more metal.</span>"
					break

			being_repaired = 0

			user << "<span class='info'>You stop repairing \the [src].</span>"

			return 0

		if(istype(I, /obj/item/weapon/weldingtool))
			if(being_repaired)
				return 0

			if(HealthPercent() < pod_config.metal_repair_threshold_percent)
				user << "<span class='warning'>\The [src] is too damaged to repair without additional metal.</span>"
				return 0

			if(HealthPercent() >= 100)
				user << "<span class='info'>\The [src] is already fully repaired.</span>"
				return 0

			var/obj/item/weapon/weldingtool/W = I

			being_repaired = 1

			user << "<span class='info'>You start to repair some damage on \the [src].</span>"
			while(do_after(user, 30) && W.isOn())
				user << "<span class='info'>You repair some damage.</span>"
				health += pod_config.welding_repair_amount
				update_icon()
				W.remove_fuel(1, user)
				if(HealthPercent() >= 100)
					user << "<span class='info'>\The [src] is now fully repaired.</span>"
					break

			being_repaired = 0

			user << "<span class='info'>You stop repairing \the [src].</span>"

			return 0

		if(istype(I, /obj/item/weapon/pen))
			var/new_name = input(user, "Please enter a new name for the pod.", "Input") as text
			new_name = strip_html(new_name)
			new_name = trim(new_name)

			user << "<span class='info'>You change the [name]'s name to [new_name].</span>"
			name = "\"[new_name]\""
			return 0

		// Give attachments a chance to handle attackby.
		for(var/obj/item/weapon/pod_attachment/attachment in GetAttachments())
			if(attachment.PodAttackbyAction(I, user))
				return 0

		Damage

		if(I.force)
			user << "<span class='attack'>You hit \the [src] with the [I].</span>"
			TakeDamage(I.force, 0, I, user)
			add_logs(user, (pilot ? pilot : 0), "attacked a space pod", 1, I, " (REMHP: [health])")
			user.changeNext_move(8)

		update_icon()

	return_air()
		if(toggles & P_TOGGLE_ENVAIR)
			return loc.return_air()
		if(internal_air)
			return internal_air
		else	..()

	remove_air(var/amt)
		if(toggles & P_TOGGLE_ENVAIR)
			var/datum/gas_mixture/env = loc.return_air()
			return env.remove(amt)
		if(internal_air)
			return internal_air.remove(amt)
		else return ..()

	proc/return_temperature()
		if(toggles & P_TOGGLE_ENVAIR)
			var/datum/gas_mixture/env = loc.return_air()
			return env.return_temperature()
		if(internal_air)
			return internal_air.return_temperature()
		else return ..()

	proc/return_pressure()
		if(toggles & P_TOGGLE_ENVAIR)
			var/datum/gas_mixture/env = loc.return_air()
			return env.return_pressure()
		if(internal_air)
			return internal_air.return_pressure()
		else return ..()

	proc/OnClick(var/atom/A, var/mob/M, var/list/modifiers = list())
		var/click_type = GetClickTypeFromList(modifiers)

		if(click_type == P_ATTACHMENT_KEYBIND_SHIFT)
			A.examine()

		if(click_type == P_ATTACHMENT_KEYBIND_CTRL)
			if(istype(A, /obj/machinery/portable_atmospherics/canister) && A in bounds(1))
				var/obj/machinery/portable_atmospherics/canister/canister = A
				if(internal_canister)
					M << "<span class='notice'>There already is a gas canister installed.</span>"
					return 0
				M << "<span class='info'>\The [src] starts to load \the [canister].</span>"
				sleep(30)
				if(src && (canister in bounds(1)) && !internal_canister)
					canister.loc = src
					internal_canister = canister
					M << "<span class='info'>\The [src] loaded \the [canister].</span>"

		if(!pilot || M != pilot)
			return 0

		for(var/obj/item/weapon/pod_attachment/attachment in attachments)
			if(attachment.keybind)
				if(attachment.keybind == click_type)
					attachment.Use(A, M)

		M.changeNext_move(3)

	Bumped(var/atom/movable/AM)
		if(istype(AM, /obj/effect/effect/water))
			if(HasDamageFlag(P_DAMAGE_FIRE))
				RemoveDamageFlag(P_DAMAGE_FIRE)
				PrintSystemNotice("Fire extinguished.")
		..()

	CtrlShiftClick(var/mob/user)
		if(!check_rights(R_SECONDARYADMIN))
			return ..()

		if(user.client)
			user.client.debug_variables(pod_log)

		OpenDebugMenu(user)
