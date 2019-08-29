{-# LANGUAGE FlexibleContexts, RankNTypes, DefaultSignatures #-}

module AST.Class.Unify
    ( Unify(..), UVarOf
    , BindingDict(..)
    ) where

import AST.Class.Nodes (KNodes(..))
import AST.Class.Recursive
import AST.Class.ZipMatch (ZipMatch)
import AST.Knot (Tree, Knot)
import AST.Unify.Error (UnifyError(..))
import AST.Unify.Constraints
import AST.Unify.QuantifiedVar (HasQuantifiedVar(..), MonadQuantify)
import AST.Unify.Term (UTerm, UTermBody, uBody)
import Control.Lens.Operators
import Data.Constraint (Dict(..))
import Data.Proxy (Proxy(..))
import Data.Kind (Type)

import Prelude.Compat

-- | Unification variable type for a unification monad
type family UVarOf (m :: Type -> Type) :: Knot -> Type

-- | BindingDict implements unification variables for a type in a unification monad.
--
-- It is parameterized on:
--
-- * `v`: The unification variable 'Knot'
-- * `m`: The 'Monad' to bind in
-- * `t`: The unified term's 'Knot'
--
-- Has 2 implementations in syntax-tree:
--
-- * 'AST.Unify.Binding.bindingDict' for pure state based unification
-- * 'AST.Unify.Binding.ST.stBinding' for 'Control.Monad.ST.ST' based unification
data BindingDict v m t = BindingDict
    { lookupVar :: Tree v t -> m (Tree (UTerm v) t)
    , newVar :: Tree (UTerm v) t -> m (Tree v t)
    , bindVar :: Tree v t -> Tree (UTerm v) t -> m ()
    }

-- | @Unify m t@ enables 'AST.Unify.unify' to perform unification for @t@ in the 'Monad' @m@.
--
-- The 'unifyRecursive' method represents the constraint that @Unify m@ applies to all recursive child nodes.
-- It replaces context for 'Unify' to avoid `UndecidableSuperClasses`.
class
    ( Eq (Tree (UVarOf m) t)
    , RTraversable t
    , ZipMatch t
    , HasTypeConstraints t
    , HasQuantifiedVar t
    , MonadScopeConstraints (TypeConstraintsOf t) m
    , MonadQuantify (TypeConstraintsOf t) (QVar t) m
    ) => Unify m t where

    -- | The implementation for unification variables binding and lookup
    binding :: BindingDict (UVarOf m) m t

    -- | Handles a unification error.
    --
    -- If 'unifyError' is called then unification has failed.
    -- A compiler implementation may present an error message based on the provided 'UnifyError' when this occurs.
    unifyError :: Tree (UnifyError t) (UVarOf m) -> m a

    -- | What to do when top-levels of terms being unified do not match.
    --
    -- Usually this will cause a 'unifyError'.
    --
    -- Some AST terms could be equivalent despite not matching structurally,
    -- like record field extentions with the fields ordered differently.
    -- Those would override the default implementation to handle the unification of mismatching structures.
    structureMismatch ::
        (forall c. Unify m c => Tree (UVarOf m) c -> Tree (UVarOf m) c -> m (Tree (UVarOf m) c)) ->
        Tree (UTermBody (UVarOf m)) t -> Tree (UTermBody (UVarOf m)) t -> m ()
    structureMismatch _ x y = unifyError (Mismatch (x ^. uBody) (y ^. uBody))

    -- TODO: Putting documentation here causes duplication in the haddock documentation
    unifyRecursive :: Proxy m -> Proxy t -> Dict (NodesConstraint t (Unify m))
    {-# INLINE unifyRecursive #-}
    default unifyRecursive ::
        NodesConstraint t (Unify m) =>
        Proxy m -> Proxy t -> Dict (NodesConstraint t (Unify m))
    unifyRecursive _ _ = Dict

instance Recursive (Unify m) where
    {-# INLINE recurse #-}
    recurse =
        unifyRecursive (Proxy @m) . p
        where
            p :: Proxy (Unify m t) -> Proxy t
            p _ = Proxy
