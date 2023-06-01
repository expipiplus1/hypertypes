{-# LANGUAGE BangPatterns #-}

-- | Unification
module Hyper.Unify
    ( unify
    , module Hyper.Class.Unify
    , module Hyper.Unify.Binding
    , module Hyper.Unify.Constraints
    , module Hyper.Unify.Error
      -- | Exported only for SPECIALIZE pragmas
    , updateConstraints
    , updateTermConstraints
    , updateTermConstraintsH
    , unifyUTerms
    , unifyUnbound
    ) where

import Algebra.PartialOrd (PartialOrd (..))
import Hyper
import Hyper.Class.Unify
import Hyper.Class.ZipMatch (zipMatchA)
import Hyper.Unify.Binding (UVar)
import Hyper.Unify.Constraints
import Hyper.Unify.Error (UnifyError (..))
import Hyper.Unify.Term (UTerm (..), UTermBody (..), uBody, uConstraints)

import Hyper.Internal.Prelude

-- TODO: implement when need / better understand motivations for -
-- occursIn, seenAs, getFreeVars, freshen, equals, equiv
-- (from unification-fd package)

{-# INLINE updateConstraints #-}
updateConstraints ::
    Unify m t =>
    TypeConstraintsOf t ->
    UVarOf m # t ->
    UTerm (UVarOf m) # t ->
    m ()
updateConstraints !newConstraints v x =
    case x of
        UUnbound l
            | newConstraints `leq` l -> pure ()
            | otherwise -> bindVar binding v (UUnbound newConstraints)
        USkolem l
            | newConstraints `leq` l -> pure ()
            | otherwise -> SkolemEscape v & unifyError
        UTerm t -> updateTermConstraints v t newConstraints
        UResolving t -> occursError v t & void
        _ -> error "updateConstraints: This shouldn't happen in unification stage"

{-# INLINE updateTermConstraints #-}
updateTermConstraints ::
    forall m t.
    Unify m t =>
    UVarOf m # t ->
    UTermBody (UVarOf m) # t ->
    TypeConstraintsOf t ->
    m ()
updateTermConstraints v t newConstraints
    | newConstraints `leq` (t ^. uConstraints) = pure ()
    | otherwise =
        do
            bindVar binding v (UResolving t)
            case verifyConstraints newConstraints (t ^. uBody) of
                Nothing -> ConstraintsViolation (t ^. uBody) newConstraints & unifyError
                Just prop ->
                    do
                        htraverse_ (Proxy @(Unify m) #> updateTermConstraintsH) prop
                        UTermBody newConstraints (t ^. uBody) & UTerm & bindVar binding v
                        \\ unifyRecursive (Proxy @m) (Proxy @t)

{-# INLINE updateTermConstraintsH #-}
updateTermConstraintsH ::
    Unify m t =>
    WithConstraint (UVarOf m) # t ->
    m ()
updateTermConstraintsH (WithConstraint c v0) =
    do
        (v1, x) <- semiPruneLookup v0
        updateConstraints c v1 x

-- | Unify unification variables
{-# INLINE unify #-}
unify ::
    forall m t.
    Unify m t =>
    UVarOf m # t ->
    UVarOf m # t ->
    m (UVarOf m # t)
unify x0 y0
    | x0 == y0 = pure x0
    | otherwise =
        do
            (x1, xu) <- semiPruneLookup x0
            if x1 == y0
                then pure x1
                else do
                    (y1, yu) <- semiPruneLookup y0
                    if x1 == y1
                        then pure x1
                        else unifyUTerms x1 xu y1 yu

{-# INLINE unifyUnbound #-}
unifyUnbound ::
    Unify m t =>
    WithConstraint (UVarOf m) # t ->
    UVarOf m # t ->
    UTerm (UVarOf m) # t ->
    m (UVarOf m # t)
unifyUnbound (WithConstraint level xv) yv yt =
    do
        updateConstraints level yv yt
        yv <$ bindVar binding xv (UToVar yv)

{-# INLINE unifyUTerms #-}
unifyUTerms ::
    forall m t.
    Unify m t =>
    UVarOf m # t ->
    UTerm (UVarOf m) # t ->
    UVarOf m # t ->
    UTerm (UVarOf m) # t ->
    m (UVarOf m # t)
unifyUTerms xv (UUnbound level) yv yt = unifyUnbound (WithConstraint level xv) yv yt
unifyUTerms xv xt yv (UUnbound level) = unifyUnbound (WithConstraint level yv) xv xt
unifyUTerms xv USkolem{} yv _ = xv <$ unifyError (SkolemUnified xv yv)
unifyUTerms xv _ yv USkolem{} = yv <$ unifyError (SkolemUnified yv xv)
unifyUTerms xv (UTerm xt) yv (UTerm yt) =
    do
        bindVar binding yv (UToVar xv)
        zipMatchA (Proxy @(Unify m) #> unify) (xt ^. uBody) (yt ^. uBody)
            & fromMaybe (xt ^. uBody <$ structureMismatch unify (xt ^. uBody) (yt ^. uBody))
            >>= bindVar binding xv . UTerm . UTermBody (xt ^. uConstraints <> yt ^. uConstraints)
        pure xv
        \\ unifyRecursive (Proxy @m) (Proxy @t)
unifyUTerms _ _ _ _ = error "unifyUTerms: This shouldn't happen in unification stage"
