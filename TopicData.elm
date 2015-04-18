module TopicData where

import Array
import Array (Array)
import Debug (crash)
import Dict
import Dict (Dict)
import Http
import Signal (..)
import String
import Result
import Maybe
import Maybe (Maybe, withDefault)
import List
import List (sortBy, (::))
import Set
import Set (Set)
import Json.Decode
import Json.Decode ( Decoder
                   , (:=)
                   , decodeString
                   , object3
                   , int
                   , string
                   , dict
                   , array
                   , float
                   , at
                   , keyValuePairs)
import Common (..)
import Viz.Stars (TokenDatum)

type alias Data =
    { topicPrevalence : Array Float
    , docTopics : Dict String (Array Float)
    , tokenTopics : Dict String (Array Float)
    , topicTokens : Dict Int (List (String, Float))
    , docMetadata : Dict String TrackInfo
    }

type alias TrackInfo =
    { trackID : String
    , title : String
    , username : String
    }

type alias TrackToken = (Maybe Int, Int, Int)

type alias TaggedToken =
    { beat_coef : Maybe Int
    , chroma : Int
    , gfcc : Int
    }

type alias TrackTokens = Array TrackToken
type alias TrackData = (String, TrackTokens)
type alias TrackTopics =
    { track : TrackInfo
    , topics: Array {x: Int, y: Float}
    }

numTopics : Data -> Int
numTopics = .topicPrevalence >> Array.length

emptyData : Data
emptyData = Data Array.empty Dict.empty Dict.empty Dict.empty Dict.empty

trackInfoDec : Decoder TrackInfo
trackInfoDec =
    object3 (TrackInfo)
      (Json.Decode.map toString <| "id" := int)
      ("title" := string)
      (at ["user", "username"] string)          

topicDist : Decoder (Dict String (Array Float))
topicDist = dict (array float)

unsafeToInt : String -> Int
unsafeToInt s =
    case (String.toInt s) of
      Ok i -> i

toIntDict : Dict String a -> Dict Int a
toIntDict = Dict.toList
            >> List.map (\(a, b) -> (unsafeToInt a, b))
            >> Dict.fromList

topicTokenDec : Decoder (Dict Int (List (String, Float)))
topicTokenDec = dict (keyValuePairs float) |> Json.Decode.map toIntDict

thresh : Int -> Float -> String -> Array Float -> Bool
thresh topic min _ arr = (nth topic arr) > min

trackToTokenTopics : Data -> TrackData -> Dict String TrackTopics
trackToTokenTopics data (track, trackTokens) =
    let topicDict = tokensToTopics data track trackTokens
        info = trackInfo data track
        f xs = Array.map (\i -> {x=i, y=1.0/toFloat (Array.length xs)}) xs
    in Dict.map (\_ v -> { track = info, topics = f v}) topicDict

tokenTopic : Data -> String -> Int -> Int
tokenTopic data dtype dnum =
    let tokName = dtype ++ (toString dnum)
        topic = Dict.get tokName (data.tokenTopics)
    in withDefault -1 <| Maybe.map argmax topic

tokensToTagged : TrackTokens -> Array TaggedToken
tokensToTagged tokens =
    Array.map (\(a, b, c) -> TaggedToken a b c) tokens

tokensToTopics : Data -> String -> TrackTokens -> Dict String (Array Int)
tokensToTopics data track allTokens =
    let getTopic = tokenTopic data
        tagged = tokensToTagged allTokens
        ofType getter = Array.map getter tagged
        get dtype getter = (dtype, Array.map (getTopic dtype) (ofType getter))
    in Dict.fromList [ get "gfccs" .gfcc
                     , get "beat_coefs" (withDefault -1 << .beat_coef)
                     , get "chroma" .chroma]
                      

getTopicsForDoc : Data -> String -> Result String (Array Float)
getTopicsForDoc data doc =
    Result.fromMaybe ("Doc " ++ doc ++ "not found") (Dict.get doc (data.docTopics))

toXY : Array Float -> Array {x: Int, y: Float}
toXY = Array.indexedMap (\i y -> {x=i, y=y})

topDocsForTopic : Int -> Data -> List TrackTopics
topDocsForTopic topic data =
    let aboveThresh = Dict.toList <| Dict.filter (thresh topic 0.1) (data.docTopics)
        getInfo t = trackInfo data (segToTrackId t)
        docs = List.map (\(k,v) -> {track=getInfo k, topics=toXY v}) aboveThresh
        topDocs = List.reverse <| sortBy (nth topic << Array.map (.y) << .topics) docs
    in  List.take 10 topDocs

topWordsForTopic : Int -> Data -> List (String, Float)
topWordsForTopic topic data =
    let topWords = Dict.get topic (data.topicTokens)
    in List.take 10 (withDefault [] topWords)

getVectors : List (String, Float) -> Data -> List TokenDatum
getVectors tokens data = crash "undefined"

noInfo : String -> TrackInfo
noInfo track = { trackID = track, title = "", username = "" }

segToTrackId : String -> String
segToTrackId seg =
    let parts = String.split "." seg
    in List.head parts

trackInfo : Data -> String -> TrackInfo
trackInfo data track =
    withDefault (noInfo track) <| Dict.get track (data.docMetadata)

topicPct : Int -> Data -> String
topicPct i data =
    let amt = withDefault 0.0 <| Array.get i (data.topicPrevalence)
        pct = toString <| amt * 100.0
    in  String.left 4 pct ++ "%"

topicOrder : Data -> List Int
topicOrder data =
    let f a = withDefault 0.0 <| Array.get a (data.topicPrevalence)
    in List.reverse <| sortBy f [0.. (numTopics data) - 1]

responseResult : Http.Response String -> Result String String
responseResult response =
    case response of
      Http.Success a -> Ok a
      Http.Waiting -> Err "Waiting for HTTP response"
      Http.Failure _ s -> Err s

updateOrFail : (a -> Data -> Data) -> Decoder a -> Result String String -> Data -> Result String Data
updateOrFail update dec resp data =
    let decoded = resp `Result.andThen` decodeString dec
    in case decoded of
      Ok x -> Ok (update x data)
      Err e -> Err e

addTopicPrevalence a data = { data | topicPrevalence <- a }
addDocTopics a data = { data | docTopics <- a }
addTokenTopics a data = { data | tokenTopics <- a }
addTopicTokens a data = { data | topicTokens <- a }
addDocMetadata a data = { data | docMetadata <- a }

fromResults : List (Result String String) -> Result String Data
fromResults results =
    let updates = 
            [ updateOrFail addTopicPrevalence (array float)
            , updateOrFail addDocTopics topicDist
            , updateOrFail addTokenTopics topicDist
            , updateOrFail addTopicTokens topicTokenDec
            , updateOrFail addDocMetadata (dict trackInfoDec)
            ]
        updates' = List.map2 (|>) results updates
    in List.foldl (flip Result.andThen) (Ok emptyData) updates'

fromResponses : Http.Response String 
    -> Http.Response String
    -> Http.Response String
    -> Http.Response String
    -> Http.Response String
    -> Result String Data
fromResponses a b c d e =
    let lst = [a, b, c, d, e]
        lst' = List.map responseResult lst
    in fromResults lst'

prefix : String
prefix = "data/"

get : String -> Signal (Http.Response String)
get fname = Http.sendGet (constant (prefix ++ fname))

loadedData : Signal (Result String Data)
loadedData =
    fromResponses <~ get "topics.json"
                      ~ get "doc_topics.json"
                      ~ get "token_topics.json"
                      ~ get "topic_tokens.json"
                      ~ get "doc_metadata.json"