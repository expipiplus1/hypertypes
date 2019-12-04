{-# LANGUAGE FlexibleContexts #-}

module Hyper.Infer
    ( infer

    , InferResultsConstraint
    , inferUVarsApplyBindings

    , module Hyper.Class.Infer
    , module Hyper.Class.Infer.Env
    , module Hyper.Class.Infer.InferOf
    , module Hyper.Infer.ScopeLevel
    , module Hyper.Infer.Result

    , -- | Exported only for SPECIALIZE pragmas
      inferH
    ) where

import qualified Control.Lens as Lens
import           Hyper
import           Hyper.Class.Infer
import           Hyper.Class.Infer.Env
import           Hyper.Class.Infer.InferOf
import           Hyper.Class.Nodes (HNodesHaveConstraint(..))
import           Hyper.Infer.Result
import           Hyper.Infer.ScopeLevel
import           Hyper.Unify (Unify, UVarOf)
import           Hyper.Unify.Apply (applyBindings)

import           Hyper.Internal.Prelude

-- | Perform Hindley-Milner type inference of a term
{-# INLINE infer #-}
infer ::
    forall m t a.
    Infer m t =>
    Ann a # t ->
    m (Ann (a :*: InferResult (UVarOf m)) # t)
infer (Ann a x) =
    withDict (inferContext (Proxy @m) (Proxy @t)) $
    inferBody (hmap (Proxy @(Infer m) #> inferH) x)
    <&> (\(xI, t) -> Ann (a :*: InferResult t) xI)

{-# INLINE inferH #-}
inferH ::
    Infer m t =>
    Ann a # t ->
    InferChild m (Ann (a :*: InferResult (UVarOf m))) # t
inferH c = infer c <&> (\i -> InferredChild i (i ^. hAnn . Lens._2 . _InferResult)) & InferChild

type InferResultsConstraint c = Recursively (InferOfConstraint (HNodesHaveConstraint c))

inferUVarsApplyBindings ::
    forall m t a.
    ( Applicative m, RTraversable t, RTraversableInferOf t
    , InferResultsConstraint (Unify m) t
    ) =>
    Ann (a :*: InferResult (UVarOf m)) # t ->
    m (Ann (a :*: InferResult (Pure :*: UVarOf m)) # t)
inferUVarsApplyBindings =
    hflipped $ htraverse $
    Proxy @RTraversableInferOf #*#
    Proxy @(InferResultsConstraint (Unify m)) #>
    Lens._2 f
    where
        f ::
            forall n.
            ( HTraversable (InferOf n)
            , InferResultsConstraint (Unify m) n
            ) =>
            InferResult (UVarOf m) # n ->
            m (InferResult (Pure :*: UVarOf m) # n)
        f = withDict (recursively (Proxy @(InferOfConstraint (HNodesHaveConstraint (Unify m)) n))) $
            withDict (inferOfConstraint (Proxy @(HNodesHaveConstraint (Unify m))) (Proxy @n)) $
            withDict (hNodesHaveConstraint (Proxy @(Unify m)) (Proxy @(InferOf n))) $
            hflipped $ htraverse $
            Proxy @(Unify m) #>
            \x -> applyBindings x <&> (:*: x)
