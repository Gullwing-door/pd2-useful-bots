if not HopLib then
	return
end

if not UsefulBots then
	UsefulBots = {}
	UsefulBots.mod_path = ModPath
	UsefulBots.settings = {
		no_crouch = true,
		dominate_enemies = 1, -- 1 = yes, 2 = assist only, 3 = no
		mark_specials = true,
		announce_low_hp = true,
		targeting_priority = {
			base_priority = 1, -- 1 = by weapon stats, 2 = by distance, 3 = vanilla
			player_aim = 4,
			critical = 2,
			marked = 1,
			damaged = 1.5,
			domination = 2,
			enemies = { -- multipliers for specific enemy types
				medic = 3,
				phalanx_minion = 1,
				phalanx_vip = 1,
				shield = 1,
				sniper = 3,
				spooc = 4,
				tank = 1,
				tank_hw = 1,
				tank_medic = 2,
				tank_mini = 1,
				taser = 2,
				turret = 1
			}
		}
	}
	UsefulBots.params = {
		dominate_enemies = {
			priority = 100,
			items = { "dialog_yes", "menu_useful_bots_assist_only", "dialog_no" }
		},
		targeting_priority = {
			priority = -1,
			max = 5,
		},
		base_priority = {
			priority = 100,
			items = { "menu_useful_bots_weapon_stats", "menu_useful_bots_distance", "menu_useful_bots_vanilla" }
		},
		enemies = {
			priority = -1,
			max = 5
		}
	}
	UsefulBots.menu_builder = MenuBuilder:new("useful_bots", UsefulBots.settings, UsefulBots.params)
end

if RequiredScript == "lib/managers/menumanager" then

	Hooks:Add("MenuManagerBuildCustomMenus", "MenuManagerBuildCustomMenusUsefulBots", function(menu_manager, nodes)
		local loc = managers.localization
		HopLib:load_localization(UsefulBots.mod_path .. "loc/", loc)
		loc:add_localized_strings({
			menu_useful_bots_medic = loc:text("ene_medic"),
			menu_useful_bots_phalanx_minion = loc:text("ene_phalanx"),
			menu_useful_bots_phalanx_vip = loc:text("ene_vip"),
			menu_useful_bots_shield = loc:text("ene_shield"),
			menu_useful_bots_sniper = loc:text("ene_sniper"),
			menu_useful_bots_spooc = loc:text("ene_spook"),
			menu_useful_bots_tank = loc:text("ene_bulldozer_1"),
			menu_useful_bots_tank_hw = loc:text("ene_bulldozer_4"),
			menu_useful_bots_tank_medic = loc:text("ene_bulldozer_medic"),
			menu_useful_bots_tank_mini = loc:text("ene_bulldozer_minigun"),
			menu_useful_bots_taser = loc:text("ene_tazer"),
			menu_useful_bots_turret = loc:text("tweak_swat_van_turret_module"),
		})
		UsefulBots.menu_builder:create_menu(nodes)
	end)

end

-- no crouch
if RequiredScript == "lib/tweak_data/charactertweakdata" then

	local init_original = CharacterTweakData.init
	function CharacterTweakData:init(...)
		local result = init_original(self, ...)
		for k, v in pairs(self) do
			if type(v) == "table" then
				if v.access == "teamAI1" and UsefulBots.settings.no_crouch then
					v.allowed_poses = { stand = true }
				end
			end
		end
		return result
	end

end

-- fully count bots for balancing multiplier
if RequiredScript == "lib/managers/group_ai_states/groupaistatebase" then

	function GroupAIStateBase:_get_balancing_multiplier(balance_multipliers)
		return balance_multipliers[math.clamp(table.count(self:all_char_criminals(), function (u_data) return not u_data.status end), 1, #balance_multipliers)]
	end

end

-- add basic upgrades to make domination work
if RequiredScript == "lib/units/player_team/teamaibase" then

	TeamAIBase.set_upgrade_value = HuskPlayerBase.set_upgrade_value
	TeamAIBase.upgrade_value = HuskPlayerBase.upgrade_value
	TeamAIBase.upgrade_level = HuskPlayerBase.upgrade_level

	Hooks:PostHook(TeamAIBase, "init", "init_ub", function (self)
		self._upgrades = self._upgrades or {}
		self._upgrade_levels = self._upgrade_levels or {}
		self._temporary_upgrades = self._temporary_upgrades or {}
		self._temporary_upgrades_map = self._temporary_upgrades_map or {}
		self:set_upgrade_value("player", "intimidate_enemies", 1)
	end)

end

-- adjust slotmask to allow attacking turrets
if RequiredScript == "lib/units/player_team/teamaibrain" then

	Hooks:PostHook(TeamAIBrain, "_reset_logic_data", "_reset_logic_data_ub", function (self)
		if UsefulBots.settings.targeting_priority.enemies.turret > 0 then
			self._logic_data.enemy_slotmask = self._logic_data.enemy_slotmask + World:make_slot_mask(25)
		end
	end)

end

-- announce low health
if RequiredScript == "lib/units/player_team/teamaidamage" then

	Hooks:PostHook(TeamAIDamage, "_apply_damage", "_apply_damage_ub", function (self)
		local t = TimerManager:game():time()
		if UsefulBots.settings.announce_low_hp and (not self._said_hurt_t or self._said_hurt_t + 10 < t) and self._health_ratio < 0.3 and not self:need_revive() and not self._unit:sound():speaking() then
			self._said_hurt_t = t
			self._unit:sound():say("g80x_plu", true, true)
		end
	end)

end

-- main bot logic
if RequiredScript == "lib/units/player_team/logics/teamailogicbase" then

	local tmp_vec = Vector3()
	Hooks:PostHook(TeamAILogicBase, "_set_attention_obj", "_set_attention_obj_ub", function (data, att, react)
		if not att or not react then
			return
		end
		-- early abort
		if data.cool or data.internal_data.acting then
			return
		end
		if data.unit:movement():chk_action_forbidden("action") or data.unit:anim_data().reload or data.unit:character_damage():is_downed() then
			return
		end
		if not att.verified or not att.unit.character_damage or att.unit:character_damage():dead() then
			return
		end
		mvector3.set(tmp_vec, att.unit:movement():m_head_pos())
		mvector3.subtract(tmp_vec, data.unit:movement():m_head_pos())
		if tmp_vec:angle(data.unit:movement():m_rot():y()) > 50 then
			return
		end
		-- intimidate
		if react == AIAttentionObject.REACT_ARREST and (not data._next_intimidate_t or data._next_intimidate_t < data.t) then
			local key = att.unit:key()
			local intimidate = TeamAILogicIdle._intimidate_progress[key]
			if not intimidate or intimidate + 1 < data.t then
				TeamAILogicIdle.intimidate_cop(data, att.unit)
				TeamAILogicIdle._intimidate_progress[key] = data.t
				data._next_intimidate_t = data.t + 2
				return
			end
		end
		-- mark
		if UsefulBots.settings.mark_specials and (not data._next_mark_t or data._next_mark_t < data.t) then
			if att.char_tweak and att.char_tweak.priority_shout and (not att.unit:contour()._contour_list or not att.unit:contour():has_id("mark_enemy")) then
				TeamAILogicAssault.mark_enemy(data, data.unit, att.unit)
				data._next_mark_t = data.t + 16
				return
			end
		end
	end)

	Hooks:PostHook(TeamAILogicBase, "on_new_objective", "on_new_objective_ub", function (data)
		if data.objective and data.objective.follow_unit then
			data._latest_follow_unit = data.objective.follow_unit
		end
	end)

end

if RequiredScript == "lib/units/player_team/logics/teamailogicidle" then

	TeamAILogicIdle._intimidate_resist = {}
	TeamAILogicIdle._intimidate_progress = {}

	-- check if unit is sabotaging device
	function TeamAILogicIdle.is_high_priority(unit, unit_movement, unit_brain)
		if not unit_movement or not unit_brain then
			return false
		end
		local data = unit_brain._logic_data and unit_brain._logic_data.internal_data
		if data and (data.tasing or data.spooc_attack) then
			return true
		end
		local anim = unit:anim_data() or {}
		if anim.hands_back or anim.surrender or anim.hands_tied then
			return false
		end
		for _, action in ipairs(unit_movement._active_actions or {}) do
			if type(action) == "table" and action:type() == "act" and action._action_desc.variant then
				local variant = action._action_desc.variant
				if variant:find("untie") or variant:find("^e_so_") or variant:find("^sabotage_") then
					return true
				end
			end
		end
		return false
	end

	function TeamAILogicIdle._find_intimidateable_civilians(criminal, use_default_shout_shape, max_angle, max_dis)
		local head_pos = criminal:movement():m_head_pos()
		local look_vec = criminal:movement():m_rot():y()
		local intimidateable_civilians = {}
		local best_civ, best_civ_wgt
		local highest_wgt = 1
		local my_tracker = criminal:movement():nav_tracker()
		local unit, unit_movement, unit_base, unit_anim_data, unit_brain, intimidatable, escort
		local ai_visibility_slotmask = managers.slot:get_mask("AI_visibility")
		max_angle = max_angle or 90
		max_dis = use_default_shout_shape and 1200 or max_dis or 400
		for key, u_data in pairs(managers.enemy:all_civilians()) do
			unit = u_data.unit
			unit_movement = unit:movement()
			unit_base = unit:base()
			unit_anim_data = unit:anim_data()
			unit_brain = unit:brain()
			escort = tweak_data.character[unit_base._tweak_table].is_escort
			intimidatable = escort and (unit_anim_data.panic or unit_anim_data.standing_hesitant) or tweak_data.character[unit_base._tweak_table].intimidateable and not unit_base.unintimidateable and not unit_anim_data.unintimidateable
			if my_tracker.check_visibility(my_tracker, unit_movement:nav_tracker()) and not unit_movement:cool() and intimidatable and not unit_brain:is_tied() and not unit:unit_data().disable_shout and (not unit_anim_data.drop or (unit_brain._logic_data.internal_data.submission_meter or 0) < (unit_brain._logic_data.internal_data.submission_max or 0) * 0.25) then
				local u_head_pos = unit_movement:m_head_pos() + math.UP * 30
				local vec = u_head_pos - head_pos
				local dis = mvector3.normalize(vec)
				local angle = vec:angle(look_vec)
				if dis < (escort and 300 or max_dis) and angle < (use_default_shout_shape and math.max(8, math.lerp(90, 30, dis / 1200)) or max_angle) then
					local ray = World:raycast("ray", head_pos, u_head_pos, "slot_mask", ai_visibility_slotmask)
					if not ray then
						local inv_wgt = dis * dis * (1 - vec:dot(look_vec))
						if escort then
							return unit, inv_wgt, { unit = unit, key = key, inv_wgt = inv_wgt }
						end
						table.insert(intimidateable_civilians, {
							unit = unit,
							key = key,
							inv_wgt = inv_wgt
						})
						if not best_civ_wgt or best_civ_wgt > inv_wgt then
							best_civ_wgt = inv_wgt
							best_civ = unit
						end
						if highest_wgt < inv_wgt then
							highest_wgt = inv_wgt
						end
					end
				end
			end
		end
		return best_civ, highest_wgt, intimidateable_civilians
	end

	function TeamAILogicIdle.intimidate_civilians(data, criminal)
		if data._next_intimidate_t and data.t < data._next_intimidate_t then
			return
		end

		data._next_intimidate_t = data.t + 2

		local best_civ, highest_wgt, intimidateable_civilians = TeamAILogicIdle._find_intimidateable_civilians(criminal, true)

		local plural = false
		if #intimidateable_civilians > 1 then
			plural = true
		elseif #intimidateable_civilians <= 0 then
			return
		end

		local is_escort = tweak_data.character[best_civ:base()._tweak_table].is_escort
		local sound_name = is_escort and "f40_any" or (best_civ:anim_data().drop and "f03a_" or "f02x_") .. (plural and "plu" or "sin")
		criminal:sound():say(sound_name, true)
		criminal:brain():action_request({
			align_sync = true,
			body_part = 3,
			type = "act",
			variant = is_escort and "cmd_point" or best_civ:anim_data().move and "gesture_stop" or "arrest"
		})
		for _, civ in ipairs(intimidateable_civilians) do
			local amount = civ.inv_wgt / highest_wgt
			if best_civ == civ.unit then
				amount = 1
			end
			civ.unit:brain():on_intimidated(amount, criminal)
		end
	end

	-- check if attention_object is a valid intimidation target
	function TeamAILogicIdle.is_valid_intimidation_target(unit, unit_tweak, unit_anim, unit_damage, data, distance)
		if UsefulBots.settings.dominate_enemies > 2 then
			return false
		end
		if unit:unit_data().disable_shout then
			return false
		end
		if not unit_tweak.surrender or unit_tweak.surrender == tweak_data.character.presets.surrender.special or unit_anim.hands_tied then
			-- unit can't surrender
			return false
		end
		if distance > tweak_data.player.long_dis_interaction.intimidate_range_enemies then
			-- too far away
			return false
		end
		if unit_anim.hands_back or unit_anim.surrender then
			-- unit is already surrendering
			return true
		end
		if UsefulBots.settings.dominate_enemies > 1 then
			-- unit is not surrendering and we only allow domination assists
			return false
		end
		if not managers.groupai:state():has_room_for_police_hostage() then
			-- no room for police hostage
			return false
		end
		local health_min
		for k, _ in pairs(unit_tweak.surrender.reasons and unit_tweak.surrender.reasons.health or {}) do
			health_min = (not health_min or k < health_min) and k or health_min
		end
		local is_hurt = health_min and unit_damage:health_ratio() < health_min
		if not is_hurt then
			-- not vulnerable
			return false
		end
		local resist = TeamAILogicIdle._intimidate_resist[unit:key()]
		if resist and resist > 1 then
			-- resisted too often
			return false
		end
		local num = 0
		local max = 1 + table.count(managers.groupai:state():all_char_criminals(), function (u_data) return u_data == "dead" end) * 2
		local m_pos = data.unit:movement():m_pos()
		local dist_sq = tweak_data.player.long_dis_interaction.intimidate_range_enemies * tweak_data.player.long_dis_interaction.intimidate_range_enemies * 4
		for _, v in pairs(data.detected_attention_objects) do
			if v.verified and v.unit ~= unit and v.unit.character_damage and not v.unit:character_damage():dead() and mvector3.distance_sq(v.unit:movement():m_pos(), m_pos) < dist_sq then
				num = num + 1
				if num > max then
					-- too many detected attention objects
					return false
				end
			end
		end
		return true
	end

	function TeamAILogicIdle.intimidate_cop(data, target)
		local anim = target:anim_data()
		data.unit:sound():say(anim.hands_back and "l03x_sin" or anim.surrender and "l02x_sin" or "l01x_sin", true)
		local new_action = {
			type = "act",
			variant = (anim.hands_back or anim.surrender) and "arrest" or "gesture_stop",
			body_part = 3,
			align_sync = true
		}
		data.unit:brain():action_request(new_action)
		target:brain():on_intimidated(tweak_data.player.long_dis_interaction.intimidate_strength, data.unit)

		local objective = target:brain():objective()
		if not objective or objective.type ~= "surrender" then
			TeamAILogicIdle._intimidate_resist[target:key()] = (TeamAILogicIdle._intimidate_resist[target:key()] or 0) + 1
		end
	end

	local math_min = math.min
	local math_max = math.max
	local math_lerp = math.lerp
	local mvec_set = mvector3.set
	local mvec_sub = mvector3.subtract
	local mvec_norm = mvector3.normalize
	local tmp_vec = Vector3()
	local _get_priority_attention_original = TeamAILogicIdle._get_priority_attention
	function TeamAILogicIdle._get_priority_attention(data, attention_objects, reaction_func, ...)
		local ub_priority = UsefulBots.settings.targeting_priority
		if ub_priority.base_priority > 2 then
			return _get_priority_attention_original(data, attention_objects, reaction_func, ...)
		end

		reaction_func = reaction_func or TeamAILogicBase._chk_reaction_to_attention_object
		local best_target, best_target_priority, best_target_reaction = nil, 0, nil
		local REACT_SHOOT = data.cool and AIAttentionObject.REACT_SURPRISED or AIAttentionObject.REACT_SHOOT
		local REACT_ARREST = AIAttentionObject.REACT_ARREST
		local REACT_AIM = AIAttentionObject.REACT_AIM
		local w_unit = data.unit:inventory():equipped_unit()
		local w_tweak = alive(w_unit) and w_unit:base():weapon_tweak_data()
		local w_usage = w_tweak and data.char_tweak.weapon[w_tweak.usage]
		local follow_movement = alive(data._latest_follow_unit) and data._latest_follow_unit:movement()
		local follow_head_pos = follow_movement and follow_movement:m_head_pos()
		local follow_look_vec = follow_movement and follow_movement:m_head_rot():y()

		for u_key, attention_data in pairs(attention_objects) do
			local att_unit = attention_data.unit
			if not attention_data.identified then
			elseif attention_data.pause_expire_t then
				if data.t > attention_data.pause_expire_t then
					attention_data.pause_expire_t = nil
				end
			elseif attention_data.stare_expire_t and data.t > attention_data.stare_expire_t then
				if attention_data.settings.pause then
					attention_data.stare_expire_t = nil
					attention_data.pause_expire_t = data.t + math.lerp(attention_data.settings.pause[1], attention_data.settings.pause[2], math.random())
				end
			elseif alive(att_unit) then
				local distance = mvector3.distance(data.m_pos, attention_data.m_pos)
				local reaction = reaction_func(data, attention_data, not CopLogicAttack._can_move(data)) or AIAttentionObject.REACT_CHECK
				attention_data.aimed_at = TeamAILogicIdle.chk_am_i_aimed_at(data, attention_data, attention_data.aimed_at and 0.95 or 0.985)
				-- attention unit data
				local att_tweak_name = att_unit.base and att_unit:base()._tweak_table
				local att_tweak = attention_data.char_tweak or att_tweak_name and tweak_data.character[att_tweak_name] or {}
				local att_brain = att_unit.brain and att_unit:brain()
				local att_anim = att_unit.anim_data and att_unit:anim_data() or {}
				local att_movement = att_unit.movement and att_unit:movement()
				local att_damage = att_unit.character_damage and att_unit:character_damage()

				local alert_dt = attention_data.alert_t and data.t - attention_data.alert_t or 10000
				local dmg_dt = attention_data.dmg_t and data.t - attention_data.dmg_t or 10000
				local mark_dt = attention_data.mark_t and data.t - attention_data.mark_t or 10000
				if data.attention_obj and data.attention_obj.u_key == u_key then
					alert_dt = alert_dt * 0.8
					dmg_dt = dmg_dt * 0.8
					mark_dt = mark_dt * 0.8
					distance = distance * 0.8
				end
				local has_alerted = alert_dt < 5
				local has_damaged = dmg_dt < 2
				local been_marked = mark_dt < 10
				local is_tied = att_anim.hands_tied
				local is_dead = not att_damage or att_damage:dead()
				local is_special = attention_data.is_very_dangerous or att_tweak.priority_shout
				local is_turret = att_unit.base and att_unit:base().sentry_gun
				-- use the dmg multiplier of the given distance as priority
				local valid_target = false
				local target_priority
				if ub_priority.base_priority == 1 and w_usage then
					local falloff_data = (TeamAIActionShoot or CopActionShoot)._get_shoot_falloff(nil, distance, w_usage.FALLOFF)
					target_priority = (falloff_data.dmg_mul / w_usage.FALLOFF[1].dmg_mul) * falloff_data.acc[2]
				else
					target_priority = math_max(0, 1 - distance / 3000)
				end

				-- fine tune target priority
				if att_unit:in_slot(data.enemy_slotmask) and not is_tied and not is_dead and attention_data.verified then
					valid_target = true

					local high_priority = TeamAILogicIdle.is_high_priority(att_unit, att_movement, att_brain)
					local should_intimidate = not high_priority and TeamAILogicIdle.is_valid_intimidation_target(att_unit, att_tweak, att_anim, att_damage, data, distance)

					-- check for reaction changes
					reaction = should_intimidate and REACT_ARREST or (high_priority or is_special or has_damaged or been_marked) and math_max(REACT_SHOOT, reaction) or reaction

					-- get target priority multipliers
					target_priority = target_priority * (should_intimidate and ub_priority.domination or 1) * (high_priority and ub_priority.critical or 1) * (has_damaged and ub_priority.damaged or 1) * (been_marked and ub_priority.marked or 1) * (is_turret and ub_priority.enemies.turret or 1) * (ub_priority.enemies[att_tweak_name] or 1)

					-- give a slight boost to priority if this is our current target (to avoid switching targets too much if the other one is still alive and visible)
					if data.attention_obj == attention_data then
						target_priority = target_priority * 1.1
					end

					-- reduce priority if we would hit a shield
					if TeamAILogicIdle._ignore_shield(data.unit, attention_data) then
						target_priority = target_priority * 0.01
					end

					-- prefer shooting enemies the player is not aiming at
					if ub_priority.player_aim ~= 1 and follow_look_vec then
						mvec_set(tmp_vec, att_movement:m_head_pos())
						mvec_sub(tmp_vec, follow_head_pos)
						mvec_norm(tmp_vec)
						target_priority = target_priority * math_lerp(ub_priority.player_aim, 1, math_max(0, follow_look_vec:dot(tmp_vec)))
					end
				elseif has_alerted and not is_dead then
					valid_target = true
					reaction = math_min(reaction, REACT_AIM)
					target_priority = target_priority * 0.01
				end

				if valid_target and target_priority > best_target_priority then
					best_target = attention_data
					best_target_priority = target_priority
					best_target_reaction = reaction
				end
			end
		end
		return best_target, best_target and 3 / math_max(best_target_priority, 0.1), best_target_reaction
	end

end

if RequiredScript == "lib/units/player_team/logics/teamailogicassault" then

	TeamAILogicAssault._mark_special_chk_t = math.huge  -- hacky way to stop the vanilla special mark code

	function TeamAILogicAssault.mark_enemy(data, criminal, to_mark)
		criminal:sound():say(to_mark:base():char_tweak().priority_shout .. "x_any", true)
		managers.network:session():send_to_peers_synched("play_distance_interact_redirect", data.unit, "cmd_point")
		data.unit:movement():play_redirect("cmd_point")
		to_mark:contour():add("mark_enemy", true)
	end

end

if RequiredScript == "lib/units/enemies/cop/logics/coplogicidle" then

	Hooks:PreHook(CopLogicIdle, "on_intimidated", "on_intimidated_ub", function (data)
		if not managers.groupai:state():is_enemy_special(data.unit) then
			TeamAILogicIdle._intimidate_progress[data.unit:key()] = data.t
		end
	end)

end

if RequiredScript == "lib/units/weapons/newnpcraycastweaponbase" then

	-- Remove criminal slotmask from Team AI so they can shoot through each other
	Hooks:PostHook(NewNPCRaycastWeaponBase, "setup", "setup_ub", function (self)
		if self._setup.user_unit and self._setup.user_unit:in_slot(16) then
			self._bullet_slotmask = self._bullet_slotmask - World:make_slot_mask(16)
		end
	end)

end
