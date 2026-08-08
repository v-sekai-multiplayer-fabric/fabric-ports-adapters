-- Standalone check of the restated authority theorems. Minimal stand-ins for
-- the surrounding definitions so this compiles without Mathlib.

inductive Action where
  | observe | interact | modify
  deriving Repr, Inhabited, DecidableEq

/-- Stand-in: the real one folds over a claim's relations. -/
opaque rebacCheck : Action → Bool

/-- Stand-in for `isAuthority view rep.hilbertCode`. -/
opaque isAuthority : Bool

/-- The decision this node is entitled to make.
    `none` means "not binding here; forward to the authority zone".

    This is the concept the original theorems described in prose but did not
    state: `rebacCheck` alone cannot express "binding", because it is a pure
    function with no notion of who is asking. -/
def bindingDecision (auth : Bool) (action : Action) : Option Bool :=
  match action with
  | .observe => some (rebacCheck action)
  | _        => if auth then some (rebacCheck action) else none

/-- The authority zone may evaluate any action. -/
theorem authority_binds_any_action (action : Action) (h : isAuthority = true) :
    bindingDecision isAuthority action = some (rebacCheck action) := by
  unfold bindingDecision
  cases action <;> simp [h]

/-- A non-authority zone cannot bind interact or modify: it must forward. -/
theorem non_authority_cannot_bind_mutation
    (action : Action) (hact : action = .interact ∨ action = .modify)
    (hnotauth : isAuthority = false) :
    bindingDecision isAuthority action = none := by
  unfold bindingDecision
  rcases hact with h | h <;> subst h <;> simp [hnotauth]

/-- An interest zone may still answer observe locally. -/
theorem interest_can_answer_observe (_hnotauth : isAuthority = false) :
    bindingDecision isAuthority .observe = some (rebacCheck .observe) := by
  unfold bindingDecision; simp
