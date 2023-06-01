{-# LANGUAGE FlexibleContexts #-}

-- | Alpha-equality for schemes
module Hyper.Syntax.Scheme.AlphaEq
    ( alphaEq
    ) where

import Control.Lens (ix)
import Hyper
import Hyper.Class.Optic (HNodeLens (..))
import Hyper.Class.ZipMatch (zipMatch_)
import Hyper.Recurse (wrapM, (#>>))
import Hyper.Syntax.Scheme
import Hyper.Unify
import Hyper.Unify.New (newTerm)
import Hyper.Unify.QuantifiedVar
import Hyper.Unify.Term (UTerm (..), uBody)

import Hyper.Internal.Prelude

makeQVarInstancesInScope ::
    forall m typ.
    UnifyGen m typ =>
    QVars # typ ->
    m (QVarInstances (UVarOf m) # typ)
makeQVarInstancesInScope (QVars foralls) =
    traverse makeSkolem foralls <&> QVarInstances
    where
        makeSkolem c = scopeConstraints (Proxy @typ) >>= newVar binding . USkolem . (c <>)

schemeBodyToType ::
    (UnifyGen m typ, HNodeLens varTypes typ, Ord (QVar typ)) =>
    varTypes # QVarInstances (UVarOf m) ->
    typ # UVarOf m ->
    m (UVarOf m # typ)
schemeBodyToType foralls x =
    case x ^? quantifiedVar >>= getForAll of
        Nothing -> newTerm x
        Just r -> pure r
    where
        getForAll v = foralls ^? hNodeLens . _QVarInstances . ix v

schemeToRestrictedType ::
    forall m varTypes typ.
    ( HTraversable varTypes
    , HNodesConstraint varTypes (UnifyGen m)
    , HasScheme varTypes m typ
    ) =>
    Pure # Scheme varTypes typ ->
    m (UVarOf m # typ)
schemeToRestrictedType (Pure (Scheme vars typ)) =
    do
        foralls <- htraverse (Proxy @(UnifyGen m) #> makeQVarInstancesInScope) vars
        wrapM (Proxy @(HasScheme varTypes m) #>> schemeBodyToType foralls) typ

goUTerm ::
    forall m t.
    Unify m t =>
    UVarOf m # t ->
    UTerm (UVarOf m) # t ->
    UVarOf m # t ->
    UTerm (UVarOf m) # t ->
    m ()
goUTerm xv USkolem{} yv USkolem{} =
    do
        bindVar binding xv (UInstantiated yv)
        bindVar binding yv (UInstantiated xv)
goUTerm xv (UInstantiated xt) yv (UInstantiated yt)
    | xv == yt && yv == xt = pure ()
    | otherwise = unifyError (SkolemEscape xv)
goUTerm xv USkolem{} yv UUnbound{} = bindVar binding yv (UToVar xv)
goUTerm xv UUnbound{} yv USkolem{} = bindVar binding xv (UToVar yv)
goUTerm xv UInstantiated{} yv UUnbound{} = bindVar binding yv (UToVar xv)
goUTerm xv UUnbound{} yv UInstantiated{} = bindVar binding xv (UToVar yv)
goUTerm _ (UToVar xv) yv yu =
    do
        xu <- lookupVar binding xv
        goUTerm xv xu yv yu
goUTerm xv xu _ (UToVar yv) =
    do
        yu <- lookupVar binding yv
        goUTerm xv xu yv yu
goUTerm xv USkolem{} yv _ = unifyError (SkolemUnified xv yv)
goUTerm xv _ yv USkolem{} = unifyError (SkolemUnified yv xv)
goUTerm xv UInstantiated{} yv _ = unifyError (SkolemUnified xv yv)
goUTerm xv _ yv UInstantiated{} = unifyError (SkolemUnified yv xv)
goUTerm xv UUnbound{} yv yu = goUTerm xv yu yv yu -- Term created in structure mismatch
goUTerm xv xu yv UUnbound{} = goUTerm xv xu yv xu -- Term created in structure mismatch
goUTerm _ (UTerm xt) _ (UTerm yt) =
    zipMatch_ (Proxy @(Unify m) #> goUVar) (xt ^. uBody) (yt ^. uBody)
        & fromMaybe (structureMismatch (\x y -> x <$ goUVar x y) (xt ^. uBody) (yt ^. uBody))
        \\ unifyRecursive (Proxy @m) (Proxy @t)
goUTerm _ _ _ _ = error "unexpected state at alpha-eq"

goUVar ::
    Unify m t =>
    UVarOf m # t ->
    UVarOf m # t ->
    m ()
goUVar xv yv =
    do
        xu <- lookupVar binding xv
        yu <- lookupVar binding yv
        goUTerm xv xu yv yu

-- Check for alpha equality. Raises a `unifyError` when mismatches.
alphaEq ::
    ( HTraversable varTypes
    , HNodesConstraint varTypes (UnifyGen m)
    , HasScheme varTypes m typ
    ) =>
    Pure # Scheme varTypes typ ->
    Pure # Scheme varTypes typ ->
    m ()
alphaEq s0 s1 =
    do
        t0 <- schemeToRestrictedType s0
        t1 <- schemeToRestrictedType s1
        goUVar t0 t1
