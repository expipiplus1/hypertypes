-- | A class for constraints for unification variables

{-# LANGUAGE FlexibleContexts, TemplateHaskell #-}

module AST.Unify.Constraints
    ( TypeConstraints(..)
    , MonadScopeConstraints(..)
    , HasTypeConstraints(..)
    , WithConstraint(..), wcConstraint, wcBody
    ) where

import Algebra.PartialOrd (PartialOrd(..))
import AST (Tree, Knot, GetKnot)
import Control.Lens (makeLenses)
import Data.Kind (Type)

import Prelude.Compat

-- | A class for constraints for unification variables.
class (PartialOrd c, Semigroup c) => TypeConstraints c where
    -- | Remove scope constraints.
    --
    -- When generalizing unification variables into universally
    -- quantified variables, and then into fresh unification variables
    -- upon instantiation, some constraints need to be carried over,
    -- and the "scope" constraints need to be erased.
    generalizeConstraints :: c -> c

    -- | Remove all constraints other than the scope constraints
    --
    -- Useful for comparing constraints to the current scope constraints
    toScopeConstraints :: c -> c

-- | A class for unification monads with scope levels
class Monad m => MonadScopeConstraints c m where
    -- | Get the current scope constraint
    scopeConstraints :: m c

-- | A class for terms that have constraints.
--
-- A dependency of `AST.Class.Unify.Unify`
class
    TypeConstraints (TypeConstraintsOf ast) =>
    HasTypeConstraints (ast :: Knot -> *) where

    type family TypeConstraintsOf (ast :: Knot -> Type) :: Type

    -- | Verify constraints on the ast and apply the given child
    -- verifier on children
    verifyConstraints ::
        TypeConstraintsOf ast ->
        Tree ast k ->
        Maybe (Tree ast (WithConstraint k))

-- | A 'Knot' to represent a term alongside a constraint.
--
-- Used for 'verifyConstraints'.
data WithConstraint k ast = WithConstraint
    { _wcConstraint :: TypeConstraintsOf (GetKnot ast)
    , _wcBody :: k ast
    }
makeLenses ''WithConstraint
