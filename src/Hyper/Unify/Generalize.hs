{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Generalization of type schemes
module Hyper.Unify.Generalize
    ( generalize
    , instantiate
    , GTerm (..)
    , _GMono
    , _GPoly
    , _GBody
    , W_GTerm (..)
    , instantiateWith
    , instantiateForAll
      -- | Exports for @SPECIALIZE@ pragmas.
    , instantiateH
    ) where

import Algebra.PartialOrd (PartialOrd (..))
import qualified Control.Lens as Lens
import Control.Monad.Trans.Class (MonadTrans (..))
import Control.Monad.Trans.Writer (WriterT (..), tell)
import Data.Monoid (All (..))
import Hyper
import Hyper.Class.Traversable
import Hyper.Class.Unify
import Hyper.Recurse
import Hyper.Unify.Constraints
import Hyper.Unify.New (newTerm)
import Hyper.Unify.Term (UTerm (..), uBody)

import Hyper.Internal.Prelude

-- | An efficient representation of a type scheme arising from
-- generalizing a unification term. Type subexpressions which are
-- completely monomoprhic are tagged as such, to avoid redundant
-- instantation and unification work
data GTerm v ast
    = -- | Completely monomoprhic term
      GMono (v ast)
    | -- | Points to a quantified variable (instantiation will
      -- create fresh unification terms) (`Hyper.Unify.Term.USkolem`
      -- or `Hyper.Unify.Term.UResolved`)
      GPoly (v ast)
    | -- | Term with some polymorphic parts
      GBody (ast :# GTerm v)
    deriving (Generic)

makePrisms ''GTerm
makeCommonInstances [''GTerm]
makeHTraversableAndBases ''GTerm

instance RNodes a => HNodes (HFlip GTerm a) where
    type HNodesConstraint (HFlip GTerm a) c = (c a, Recursive c)
    type HWitnessType (HFlip GTerm a) = HRecWitness a
    {-# INLINE hLiftConstraint #-}
    hLiftConstraint (HWitness HRecSelf) = \_ x -> x
    hLiftConstraint (HWitness (HRecSub c n)) = hLiftConstraintH c n

hLiftConstraintH ::
    forall a c b n r.
    (RNodes a, HNodesConstraint (HFlip GTerm a) c) =>
    HWitness a b ->
    HRecWitness b n ->
    Proxy c ->
    (c n => r) ->
    r
hLiftConstraintH c n p f =
    (Proxy @RNodes #> (p #> (p #> f) (HWitness @(HFlip GTerm _) n)) c) c
        \\ recurse (Proxy @(c a))
        \\ recurse (Proxy @(RNodes a))

instance Recursively HFunctor ast => HFunctor (HFlip GTerm ast) where
    {-# INLINE hmap #-}
    hmap f =
        _HFlip
            %~ \case
                GMono x -> f (HWitness HRecSelf) x & GMono
                GPoly x -> f (HWitness HRecSelf) x & GPoly
                GBody x ->
                    hmap
                        ( Proxy @(Recursively HFunctor) #*#
                            \cw ->
                                hflipped
                                    %~ hmap (f . (\(HWitness nw) -> HWitness (HRecSub cw nw)))
                        )
                        x
                        & GBody
                        \\ recursively (Proxy @(HFunctor ast))

instance Recursively HFoldable ast => HFoldable (HFlip GTerm ast) where
    {-# INLINE hfoldMap #-}
    hfoldMap f =
        \case
            GMono x -> f (HWitness HRecSelf) x
            GPoly x -> f (HWitness HRecSelf) x
            GBody x ->
                hfoldMap
                    ( Proxy @(Recursively HFoldable) #*#
                        \cw ->
                            hfoldMap (f . (\(HWitness nw) -> HWitness (HRecSub cw nw)))
                                . (_HFlip #)
                    )
                    x
                    \\ recursively (Proxy @(HFoldable ast))
            . (^. _HFlip)

instance RTraversable ast => HTraversable (HFlip GTerm ast) where
    {-# INLINE hsequence #-}
    hsequence =
        \case
            GMono x -> runContainedH x <&> GMono
            GPoly x -> runContainedH x <&> GPoly
            GBody x ->
                -- HTraversable will be required when not implied by Recursively
                htraverse (Proxy @RTraversable #> hflipped hsequence) x
                    \\ recurse (Proxy @(RTraversable ast))
                    <&> GBody
            & _HFlip

-- | Generalize a unification term pointed by the given variable to a `GTerm`.
-- Unification variables that are scoped within the term
-- become universally quantified skolems.
generalize ::
    forall m t.
    UnifyGen m t =>
    UVarOf m # t ->
    m (GTerm (UVarOf m) # t)
generalize v0 =
    do
        (v1, u) <- semiPruneLookup v0
        c <- scopeConstraints (Proxy @t)
        case u of
            UUnbound l
                | toScopeConstraints l `leq` c ->
                    GPoly v1
                        <$
                        -- We set the variable to a skolem,
                        -- so additional unifications after generalization
                        -- (for example hole resumptions where supported)
                        -- cannot unify it with anything.
                        bindVar binding v1 (USkolem (generalizeConstraints l))
            USkolem l | toScopeConstraints l `leq` c -> pure (GPoly v1)
            UTerm t ->
                do
                    bindVar binding v1 (UResolving t)
                    b <- htraverse (Proxy @(UnifyGen m) #> generalize) (t ^. uBody)
                    bindVar binding v1 (UTerm t)
                    pure
                        ( if hfoldMap (Proxy @(UnifyGen m) #> All . Lens.has _GMono) b ^. Lens._Wrapped
                            then GMono v1
                            else GBody b
                        )
                    \\ unifyGenRecursive (Proxy @m) (Proxy @t)
            UResolving t -> GMono v1 <$ occursError v1 t
            _ -> pure (GMono v1)

{-# INLINE instantiateForAll #-}
instantiateForAll ::
    forall m t.
    UnifyGen m t =>
    (TypeConstraintsOf t -> UTerm (UVarOf m) # t) ->
    UVarOf m # t ->
    WriterT [m ()] m (UVarOf m # t)
instantiateForAll cons x =
    lift (lookupVar binding x)
        >>= \case
            USkolem l ->
                do
                    tell [bindVar binding x (USkolem l)]
                    r <- scopeConstraints (Proxy @t) >>= newVar binding . cons . (<> l) & lift
                    UInstantiated r & bindVar binding x & lift
                    pure r
            UInstantiated v -> pure v
            _ -> error "unexpected state at instantiate's forall"

-- TODO: Better name?
{-# INLINE instantiateH #-}
instantiateH ::
    forall m t.
    UnifyGen m t =>
    (forall n. TypeConstraintsOf n -> UTerm (UVarOf m) # n) ->
    GTerm (UVarOf m) # t ->
    WriterT [m ()] m (UVarOf m # t)
instantiateH _ (GMono x) = pure x
instantiateH cons (GPoly x) = instantiateForAll cons x
instantiateH cons (GBody x) =
    htraverse (Proxy @(UnifyGen m) #> instantiateH cons) x
        >>= lift
            . newTerm
        \\ unifyGenRecursive (Proxy @m) (Proxy @t)

{-# INLINE instantiateWith #-}
instantiateWith ::
    forall m t a.
    UnifyGen m t =>
    m a ->
    (forall n. TypeConstraintsOf n -> UTerm (UVarOf m) # n) ->
    GTerm (UVarOf m) # t ->
    m (UVarOf m # t, a)
instantiateWith action cons g =
    do
        (r, recover) <- runWriterT (instantiateH cons g)
        action <* sequence_ recover <&> (r,)

-- | Instantiate a generalized type with fresh unification variables
-- for the quantified variables
{-# INLINE instantiate #-}
instantiate ::
    UnifyGen m t =>
    GTerm (UVarOf m) # t ->
    m (UVarOf m # t)
instantiate g = instantiateWith (pure ()) UUnbound g <&> (^. Lens._1)
