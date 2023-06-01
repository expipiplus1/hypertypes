{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Hindley-Milner type inference with ergonomic blame assignment.
--
-- 'blame' is a type-error blame assignment algorithm for languages with Hindley-Milner type inference,
-- but __/without generalization of intermediate terms/__.
-- This means that it is not suitable for languages with let-generalization.
-- 'Hyper.Type.AST.Let.Let' is an example of a term that is not suitable for this algorithm.
--
-- With the contemporary knowledge that
-- ["Let Should Not Be Generalised"](https://www.microsoft.com/en-us/research/publication/let-should-not-be-generalised/),
-- as argued by luminaries such as Simon Peyton Jones,
-- optimistically this limitation shouldn't apply to new programming languages.
-- This blame assignment algorithm can also be used in a limited sense for existing languages,
-- which do have let-generalization, to provide better type errors
-- in specific definitions which don't happen to use generalizing terms.
--
-- The algorithm is pretty simple:
--
-- * Invoke all the 'inferBody' calls as 'Hyper.Infer.infer' normally would,
--   but with one important difference:
--   where 'inferBody' would normally get the actual inference results of its child nodes,
--   placeholders are generated in their place
-- * Globally sort all of the tree nodes according to a given node prioritization
--   (this prioritization would be custom for each language)
-- * According to the order of prioritization,
--   attempt to unify each infer-result with its placeholder using 'inferOfUnify'.
--   If a unification fails, roll back its state changes.
--   The nodes whose unification failed are the ones assigned with type errors.
--
-- [Lamdu](https://github.com/lamdu/lamdu) uses this algorithm for its "insist type" feature,
-- which moves around the blame for type mismatches.
--
-- Note: If a similar algorithm already existed somewhere,
-- [I](https://github.com/yairchu/) would very much like to know!
module Hyper.Infer.Blame
    ( blame
    , Blame (..)
    , BlameResult (..)
    , _Good
    , _Mismatch
    , InferOf'
    ) where

import qualified Control.Lens as Lens
import Control.Monad.Except (MonadError (..))
import Data.List (sortOn)
import Hyper
import Hyper.Class.Infer
import Hyper.Class.Traversable (ContainedH (..))
import Hyper.Class.Unify (UVarOf, UnifyGen)
import Hyper.Infer.Result
import Hyper.Recurse
import Hyper.Unify.New (newUnbound)
import Hyper.Unify.Occurs (occursCheck)

import Hyper.Internal.Prelude

-- | Class implementing some primitives needed by the 'blame' algorithm
--
-- The 'blamableRecursive' method represents that 'Blame' applies to all recursive child nodes.
-- It replaces context for 'Blame' to avoid @UndecidableSuperClasses@.
class
    (Infer m t, RTraversable t, HTraversable (InferOf t), HPointed (InferOf t)) =>
    Blame m t
    where
    -- | Unify the types/values in infer results
    inferOfUnify ::
        Proxy t ->
        InferOf t # UVarOf m ->
        InferOf t # UVarOf m ->
        m ()

    -- | Check whether two infer results are the same
    inferOfMatches ::
        Proxy t ->
        InferOf t # UVarOf m ->
        InferOf t # UVarOf m ->
        m Bool

    -- TODO: Putting documentation here causes duplication in the haddock documentation
    blamableRecursive :: Proxy m -> RecMethod (Blame m) t
    {-# INLINE blamableRecursive #-}
    default blamableRecursive :: HNodesConstraint t (Blame m) => Proxy m -> RecMethod (Blame m) t
    blamableRecursive _ _ = Dict

instance Recursive (Blame m) where
    recurse = blamableRecursive (Proxy @m) . proxyArgument

-- | A type synonym to help 'BlameResult' be more succinct
type InferOf' e v = InferOf (GetHyperType e) # v

prepareH ::
    forall m exp a.
    Blame m exp =>
    Ann a # exp ->
    m (Ann (a :*: InferResult (UVarOf m) :*: InferResult (UVarOf m)) # exp)
prepareH t =
    hpure (Proxy @(UnifyGen m) #> MkContainedH newUnbound)
        & hsequence
        >>= (`prepare` t)
        \\ inferContext (Proxy @m) (Proxy @exp)

prepare ::
    forall m exp a.
    Blame m exp =>
    InferOf exp # UVarOf m ->
    Ann a # exp ->
    m (Ann (a :*: InferResult (UVarOf m) :*: InferResult (UVarOf m)) # exp)
prepare resFromPosition (Ann a x) =
    hmap
        ( Proxy @(Blame m) #>
            InferChild . fmap (\t -> InferredChild t (t ^. hAnn . Lens._2 . Lens._1 . _InferResult)) . prepareH
        )
        x
        \\ recurse (Proxy @(Blame m exp))
        & inferBody
        <&> \(xI, r) ->
            Ann (a :*: InferResult resFromPosition :*: InferResult r) xI

tryUnify ::
    forall err m top exp.
    (MonadError err m, Blame m exp) =>
    HWitness top exp ->
    InferOf exp # UVarOf m ->
    InferOf exp # UVarOf m ->
    m ()
tryUnify _ i0 i1 =
    do
        inferOfUnify (Proxy @exp) i0 i1
        htraverse_ (Proxy @(UnifyGen m) #> occursCheck) i0
            \\ inferContext (Proxy @m) (Proxy @exp)
        & (`catchError` const (pure ()))

data BlameResult v e
    = Good (InferOf' e v)
    | Mismatch (InferOf' e v, InferOf' e v)
    deriving (Generic)
makePrisms ''BlameResult
makeCommonInstances [''BlameResult]

finalize ::
    forall a m exp.
    Blame m exp =>
    Ann (a :*: InferResult (UVarOf m) :*: InferResult (UVarOf m)) # exp ->
    m (Ann (a :*: BlameResult (UVarOf m)) # exp)
finalize (Ann (a :*: InferResult i0 :*: InferResult i1) x) =
    do
        match <- inferOfMatches (Proxy @exp) i0 i1
        let result
                | match = Good i0
                | otherwise = Mismatch (i0, i1)
        htraverse (Proxy @(Blame m) #> finalize) x
            <&> Ann (a :*: result)
        \\ recurse (Proxy @(Blame m exp))

-- | Perform Hindley-Milner type inference with prioritised blame for type error,
-- given a prioritisation for the different nodes.
--
-- The purpose of the prioritisation is to place the errors in nodes where
-- the resulting errors will be easier to understand.
--
-- The expected `MonadError` behavior is that catching errors rolls back their state changes
-- (i.e @StateT s (Either e)@ is suitable but @EitherT e (State s)@ is not)
--
-- Gets the top-level type for the term for support of recursive definitions,
-- where the top-level type of the term may be in the scope of the inference monad.
blame ::
    forall priority err m exp a.
    ( Ord priority
    , MonadError err m
    , Blame m exp
    ) =>
    (forall n. a # n -> priority) ->
    InferOf exp # UVarOf m ->
    Ann a # exp ->
    m (Ann (a :*: BlameResult (UVarOf m)) # exp)
blame order topLevelType e =
    do
        p <- prepare topLevelType e
        hfoldMap
            ( Proxy @(Blame m) #*#
                \w (a :*: InferResult i0 :*: InferResult i1) ->
                    [(order a, tryUnify w i0 i1)]
            )
            (_HFlip # p)
            & sortOn fst
            & traverse_ snd
        finalize p
