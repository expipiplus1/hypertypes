-- | Generate new unification variables

module AST.Unify.New
    ( newUnbound, newTerm, unfreeze
    ) where

import AST (Tree, Pure)
import AST.Class.Unify (Unify(..), UVarOf, BindingDict(..))
import AST.Recurse (wrapM, (#>>))
import AST.Unify.Constraints (MonadScopeConstraints(..))
import AST.Unify.Term (UTerm(..), UTermBody(..))
import Data.Proxy (Proxy(..))

import Prelude.Compat

-- | Create a new unbound unification variable in the current scope
{-# INLINE newUnbound #-}
newUnbound :: Unify m t => m (Tree (UVarOf m) t)
newUnbound = scopeConstraints >>= newVar binding . UUnbound

-- | Create a new unification term with a given body
{-# INLINE newTerm #-}
newTerm :: Unify m t => Tree t (UVarOf m) -> m (Tree (UVarOf m) t)
newTerm x = scopeConstraints >>= newVar binding . UTerm . (`UTermBody` x)

-- | Embed a pure term as a unification term
{-# INLINE unfreeze #-}
unfreeze ::
    forall m t.
    Unify m t =>
    Tree Pure t -> m (Tree (UVarOf m) t)
unfreeze = wrapM (Proxy @(Unify m) #>> newTerm)
