{-# LANGUAGE NoImplicitPrelude, ScopedTypeVariables, FlexibleContexts #-}

module AST.Unify.New
    ( newUnbound, newTerm, unfreeze
    ) where

import AST (Tree, Pure)
import AST.Class.Recursive (Recursive, wrapM)
import AST.Class.Unify (Unify(..), UVarOf, BindingDict(..))
import AST.Unify.Constraints (MonadScopeConstraints(..))
import AST.Unify.Term (UTerm(..), UTermBody(..))
import Data.Proxy (Proxy(..))

import Prelude.Compat

{-# INLINE newUnbound #-}
newUnbound :: Unify m t => m (Tree (UVarOf m) t)
newUnbound = scopeConstraints >>= newVar binding . UUnbound

{-# INLINE newTerm #-}
newTerm :: Unify m t => Tree t (UVarOf m) -> m (Tree (UVarOf m) t)
newTerm x = scopeConstraints >>= newVar binding . UTerm . (`UTermBody` x)

-- | Embed a pure term as a unification term.
unfreeze ::
    forall m t.
    Recursive (Unify m) t =>
    Tree Pure t -> m (Tree (UVarOf m) t)
unfreeze = wrapM (Proxy :: Proxy (Unify m)) newTerm