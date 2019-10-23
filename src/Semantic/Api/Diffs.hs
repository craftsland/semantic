{-# LANGUAGE AllowAmbiguousTypes, ConstraintKinds, LambdaCase, MonoLocalBinds, QuantifiedConstraints, RankNTypes #-}
module Semantic.Api.Diffs
  ( parseDiffBuilder
  , DiffOutputFormat(..)
  , diffGraph

  , DiffEffects

  , diffTerms
  ) where

import           Analysis.ConstructorName (ConstructorName)
import           Control.Effect.Error
import           Control.Effect.Parse
import           Control.Effect.Reader
import           Control.Exception
import           Control.Lens
import           Control.Monad.IO.Class
import           Data.Blob
import           Data.ByteString.Builder
import           Data.Edit
import           Data.Graph
import           Data.JSON.Fields
import           Data.Language
import           Data.ProtoLens (defMessage)
import           Data.Term
import qualified Data.Text as T
import           Diffing.Algorithm (Diffable)
import           Diffing.Interpreter (DiffTerms(..))
import           Parsing.Parser
import           Prologue
import           Proto.Semantic as P hiding (Blob, BlobPair)
import           Proto.Semantic_Fields as P
import           Proto.Semantic_JSON()
import           Rendering.Graph
import           Rendering.JSON hiding (JSON)
import qualified Rendering.JSON
import           Semantic.Api.Bridge
import           Semantic.Config
import           Semantic.Task as Task
import           Semantic.Telemetry as Stat
import           Serializing.Format hiding (JSON)
import qualified Serializing.Format as Format
import           Source.Loc

data DiffOutputFormat
  = DiffJSONTree
  | DiffJSONGraph
  | DiffSExpression
  | DiffShow
  | DiffDotGraph
  deriving (Eq, Show)

parseDiffBuilder :: (Traversable t, DiffEffects sig m) => DiffOutputFormat -> t BlobPair -> m Builder
parseDiffBuilder DiffJSONTree    = distributeFoldMap jsonDiff >=> serialize Format.JSON -- NB: Serialize happens at the top level for these two JSON formats to collect results of multiple blob pairs.
parseDiffBuilder DiffJSONGraph   = diffGraph >=> serialize Format.JSON
parseDiffBuilder DiffSExpression = distributeFoldMap (diffWith sexprDiffParsers sexprDiff)
parseDiffBuilder DiffShow        = distributeFoldMap (diffWith showDiffParsers showDiff)
parseDiffBuilder DiffDotGraph    = distributeFoldMap (diffWith dotGraphDiffParsers dotGraphDiff)

jsonDiff :: DiffEffects sig m => BlobPair -> m (Rendering.JSON.JSON "diffs" SomeJSON)
jsonDiff blobPair = diffWith jsonTreeDiffParsers (pure . jsonTreeDiff blobPair) blobPair `catchError` jsonError blobPair

jsonError :: Applicative m => BlobPair -> SomeException -> m (Rendering.JSON.JSON "diffs" SomeJSON)
jsonError blobPair (SomeException e) = pure $ renderJSONDiffError blobPair (show e)

diffGraph :: (Traversable t, DiffEffects sig m) => t BlobPair -> m DiffTreeGraphResponse
diffGraph blobs = do
  graph <- distributeFor blobs go
  pure $ defMessage & P.files .~ toList graph
  where
    go :: DiffEffects sig m => BlobPair -> m DiffTreeFileGraph
    go blobPair = diffWith jsonGraphDiffParsers (pure . jsonGraphDiff blobPair) blobPair
      `catchError` \(SomeException e) ->
        pure $ defMessage
          & P.path .~ path
          & P.language .~ lang
          & P.vertices .~ mempty
          & P.edges .~ mempty
          & P.errors .~ [defMessage & P.error .~ T.pack (show e)]
      where
        path = T.pack $ pathForBlobPair blobPair
        lang = bridging # languageForBlobPair blobPair

type DiffEffects sig m = (Member (Error SomeException) sig, Member (Reader Config) sig, Member Telemetry sig, Member Distribute sig, Member Parse sig, Carrier sig m, MonadIO m)


dotGraphDiffParsers :: Map Language (SomeParser DOTGraphDiff Loc)
dotGraphDiffParsers = aLaCarteParsers

class DiffTerms term => DOTGraphDiff term where
  dotGraphDiff :: (Carrier sig m, Member (Reader Config) sig) => DiffFor term Loc Loc -> m Builder

instance (ConstructorName syntax, Diffable syntax, Eq1 syntax, Hashable1 syntax, Traversable syntax) => DOTGraphDiff (Term syntax) where
  dotGraphDiff = serialize (DOT (diffStyle "diffs")) . renderTreeGraph


jsonGraphDiffParsers :: Map Language (SomeParser JSONGraphDiff Loc)
jsonGraphDiffParsers = aLaCarteParsers

class DiffTerms term => JSONGraphDiff term where
  jsonGraphDiff :: BlobPair -> DiffFor term Loc Loc -> DiffTreeFileGraph

instance (ConstructorName syntax, Diffable syntax, Eq1 syntax, Hashable1 syntax, Traversable syntax) => JSONGraphDiff (Term syntax) where
  jsonGraphDiff blobPair diff
    = let graph = renderTreeGraph diff
          toEdge (Edge (a, b)) = defMessage & P.source .~ a^.diffVertexId & P.target .~ b^.diffVertexId
          path = T.pack $ pathForBlobPair blobPair
          lang = bridging # languageForBlobPair blobPair
      in defMessage
           & P.path .~ path
           & P.language .~ lang
           & P.vertices .~ vertexList graph
           & P.edges .~ fmap toEdge (edgeList graph)
           & P.errors .~ mempty


jsonTreeDiffParsers :: Map Language (SomeParser JSONTreeDiff Loc)
jsonTreeDiffParsers = aLaCarteParsers

class DiffTerms term => JSONTreeDiff term where
  jsonTreeDiff :: BlobPair -> DiffFor term Loc Loc -> Rendering.JSON.JSON "diffs" SomeJSON

instance (Diffable syntax, Eq1 syntax, Hashable1 syntax, ToJSONFields1 syntax, Traversable syntax) => JSONTreeDiff (Term syntax) where
  jsonTreeDiff = renderJSONDiff


sexprDiffParsers :: Map Language (SomeParser SExprDiff Loc)
sexprDiffParsers = aLaCarteParsers

class DiffTerms term => SExprDiff term where
  sexprDiff :: (Carrier sig m, Member (Reader Config) sig) => DiffFor term Loc Loc -> m Builder

instance (ConstructorName syntax, Diffable syntax, Eq1 syntax, Hashable1 syntax, Traversable syntax) => SExprDiff (Term syntax) where
  sexprDiff = serialize (SExpression ByConstructorName)


showDiffParsers :: Map Language (SomeParser ShowDiff Loc)
showDiffParsers = aLaCarteParsers

class DiffTerms term => ShowDiff term where
  showDiff :: (Carrier sig m, Member (Reader Config) sig) => DiffFor term Loc Loc -> m Builder

instance (Diffable syntax, Eq1 syntax, Hashable1 syntax, Show1 syntax, Traversable syntax) => ShowDiff (Term syntax) where
  showDiff = serialize Show


-- | Parse a 'BlobPair' using one of the provided parsers, diff the resulting terms, and run an action on the abstracted diff.
--
-- This allows us to define features using an abstract interface, and use them with diffs for any parser whose terms support that interface.
diffWith
  :: (forall term . c term => DiffTerms term, DiffEffects sig m)
  => Map Language (SomeParser c Loc)                            -- ^ The set of parsers to select from.
  -> (forall term . c term => DiffFor term Loc Loc -> m output) -- ^ A function to run on the computed diff. Note that the diff is abstract (it’s the diff type corresponding to an abstract term type), but the term type is constrained by @c@, allowing you to do anything @c@ allows, and requiring that all the input parsers produce terms supporting @c@.
  -> BlobPair                                                   -- ^ The blob pair to parse.
  -> m output
diffWith parsers render = parsePairWith parsers (render <=< diffTerms)

diffTerms :: (DiffTerms term, Member Telemetry sig, Carrier sig m, MonadIO m)
  => Edit (Blob, term ann) (Blob, term ann) -> m (DiffFor term ann ann)
diffTerms terms = time "diff" languageTag $ do
  let diff = diffTermPair (bimap snd snd terms)
  diff <$ writeStat (Stat.count "diff.nodes" (bilength diff) languageTag)
  where languageTag = languageTagForBlobPair blobs
        blobs = bimap fst fst terms
