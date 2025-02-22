local action_request_original = TeamAIMovement.action_request
function TeamAIMovement:action_request(action_desc, ...)
	if not self:can_request_actions() then
		return
	end

	-- Wait a bit before ending shoot action
	if action_desc.body_part == 3 then
		if action_desc.type == "idle" and not action_desc.skip_wait then
			local t = TimerManager:game():time()
			if not self._switch_upper_body_to_idle_t then
				self._switch_upper_body_to_idle_t = t + 4
				return
			elseif self._switch_upper_body_to_idle_t > t then
				return
			end
		end

		self._switch_upper_body_to_idle_t = nil
	end

	return action_request_original(self, action_desc, ...)
end

if Keepers or not Network:is_server() then
	return
end

TeamAIMovement.chk_action_forbidden = CopMovement.chk_action_forbidden

Hooks:PostHook(TeamAIMovement, "set_should_stay", "set_should_stay_ub", function (self, should_stay, pos)
	if should_stay and pos then
		self._should_stay_pos = mvector3.copy(pos)
	end
	self._ext_brain:set_objective(managers.groupai:state():_determine_objective_for_criminal_AI(self._unit))
end)
