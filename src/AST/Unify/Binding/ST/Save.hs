{-# LANGUAGE NoImplicitPrelude, ScopedTypeVariables, FlexibleContexts, LambdaCase #-}

module AST.Unify.Binding.ST.Save
    ( save
    ) where

import           AST
import           AST.Class.HasChild (HasChild(..))
import           AST.Unify.Binding.Pure (PureBinding, _PureBinding)
import           AST.Unify.Binding.ST (STVar(..))
import           AST.Unify.Term (UTerm(..), uBody)
import qualified Control.Lens as Lens
import           Control.Lens.Operators
import           Control.Monad.ST.Class (MonadST(..))
import           Control.Monad.Trans.State (StateT(..))
import           Data.Functor.Const (Const(..))
import           Data.Proxy (Proxy(..))
import qualified Data.Sequence as Sequence
import           Data.STRef (readSTRef, writeSTRef)

import           Prelude.Compat

saveUTerm ::
    forall m typeVars t.
    ( MonadST m
    , Recursive (HasChild typeVars) t
    ) =>
    Tree (UTerm (STVar (World m))) t ->
    StateT (Tree typeVars PureBinding, [m ()]) m (Tree (UTerm (Const Int)) t)
saveUTerm (UUnbound c) = UUnbound c & pure
saveUTerm (USkolem c) = USkolem c & pure
saveUTerm (UVar v) = saveVar v <&> UVar
saveUTerm (UTerm u) =
    recursive (Proxy :: Proxy (HasChild typeVars t)) $
    uBody saveBody u <&> UTerm
saveUTerm UInstantiated{} = error "converting bindings during instantiation"
saveUTerm UResolving{} = error "converting bindings after resolution"
saveUTerm UResolved{} = error "converting bindings after resolution"
saveUTerm UConverted{} = error "converting variable again"

saveVar ::
    ( MonadST m
    , Recursive (HasChild typeVars) t
    ) =>
    Tree (STVar (World m)) t ->
    StateT (Tree typeVars PureBinding, [m ()]) m (Tree (Const Int) t)
saveVar (STVar v) =
    readSTRef v & liftST
    >>=
    \case
    UConverted i -> pure (Const i)
    srcBody ->
        do
            pb <- Lens.use (Lens._1 . getChild)
            let r = pb ^. _PureBinding & Sequence.length
            UConverted r & writeSTRef v & liftST
            Lens._2 %= (<> [liftST (writeSTRef v srcBody)])
            dstBody <- saveUTerm srcBody
            Lens._1 . getChild .= (pb & _PureBinding %~ (Sequence.|> dstBody))
            Const r & pure

saveBody ::
    forall m typeVars t.
    ( MonadST m
    , ChildrenWithConstraint t (Recursive (HasChild typeVars))
    ) =>
    Tree t (STVar (World m)) ->
    StateT (Tree typeVars PureBinding, [m ()]) m (Tree t (Const Int))
saveBody =
    children (Proxy :: Proxy (Recursive (HasChild typeVars))) saveVar

save ::
    ( MonadST m
    , ChildrenWithConstraint t (Recursive (HasChild typeVars))
    ) =>
    Tree t (STVar (World m)) ->
    StateT (Tree typeVars PureBinding) m (Tree t (Const Int))
save collection =
    StateT $
    \dstState ->
    do
        (r, (finalState, recover)) <- runStateT (saveBody collection) (dstState, [])
        (r, finalState) <$ sequence_ recover
