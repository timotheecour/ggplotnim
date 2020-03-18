import tables, algorithm, sequtils, random, sets, math, macros

import ggplot_types, formula, ggplot_utils
import ggplotnim / colormaps / viridisRaw
import postprocess_scales

import persvector

import ginger except Scale

proc addIdentityData(data: var seq[Value], df: DataFrame, col: FormulaNode) =
  for val in col.evaluate(df):
    data.add val

proc drawSampleIdx(sHigh: int, num = 100, seed = 42): seq[int] =
  ## draws `num` random sample indices with the seed `42` from the given `s`
  var r = initRand(seed) # for now just set a local state
  let idxNum = min(num - 1, sHigh)
  result = toSeq(0 .. idxNum).mapIt(r.rand(sHigh))

proc guessType(s: seq[Value], drawSamples: static bool = true): ValueKind =
  ## returns a ``guess`` (!) of the data type stored in `s`.
  ## We check a subset of 100 elements of the seq (or the whole if
  ## < 100 elements) and see if they match a single ValueKind.
  ## If they do match, return it, else return `VNull`
  when drawSamples:
    let indices = drawSampleIdx(s.high)
  else:
    # else we take all values as our indices
    let indices = toSeq(0 .. s.high)
  result = VNull
  var resultSet = false
  for i in indices:
    if not resultSet:
      result = s[i].kind
      resultSet = true
    else:
      if result != s[i].kind:
        case result
        of VInt, VFloat:
          result = VFloat
        else:
          return VNull

proc isDiscreteData(s: seq[Value], drawSamples: static bool = true): bool =
  ## returns an ``estimate`` (!) of whether the given sequence of
  ## data is most likely discrete or continuous. First determine
  ## most probable type, then check for discreteness
  ## - if Values are strings: discrete
  ## - if float / int: generate set of first 100 elements, check
  ##   if cardinality of set > 50: continuous, else discrete
  ## - if bool: discrete
  let guessedT = s.guessType(drawSamples = drawSamples)
  # TODO: Improve error messages in the case of guessedT == VNull
  # or change handling of that case
  case guessedT
  of VFloat, VInt:
    # same approach as in `guessType`
    when drawSamples:
      let indices = drawSampleIdx(s.high)
    else:
      let indices = toSeq(0 .. s.high)
    let elements = indices.mapIt(s[it]).toHashSet
    if elements.card > (indices.len.float / 8.0).round.int:
      result = false
    else:
      result = true
  of VString:
    # while the "discreteness" condition above might not always be satisfied for
    # strings, how would we represent string data on continuous scales?
    result = true
  of VBool:
    result = true
  of VNull:
    raise newException(ValueError, "Either `guessType` failed to determine the type " &
      "due to multiple base types in the column or the data is really `VNull`")
    #result = false
  of VObject:
     raise newException(Exception, "A VObject can neither be discrete nor continuous!")

proc discreteAndType(df: DataFrame, col: FormulaNode,
                     dcKind: Option[DiscreteKind] = none[DiscreteKind]()):
    tuple[isDiscrete: bool, vKind: ValueKind] =
  ## deteremines both the `ValueKind` of the given column as well whether that
  ## data is discrete.
  let indices = drawSampleIdx(df.high)
  let data = indices.mapIt(col.evaluate(df, it))
  let isDiscrete = block:
    if dcKind.isSome:
      let dc = dcKind.get
      dc == dcDiscrete
    else:
      isDiscreteData(data, drawSamples = false)
  result = (isDiscrete: isDiscrete,
            vKind: guessType(data, drawSamples = false))

proc discreteAndType(data: seq[Value],
                     dcKind: Option[DiscreteKind] = none[DiscreteKind]()):
    tuple[isDiscrete: bool, vKind: ValueKind] =
  ## deteremines both the `ValueKind` of the given column as well whether that
  ## data is discrete.
  let indices = drawSampleIdx(data.high)
  let data = indices.mapIt(data[it])
  let isDiscrete = block:
    if dcKind.isSome:
      let dc = dcKind.get
      dc == dcDiscrete
    else:
      isDiscreteData(data, drawSamples = false)
  result = (isDiscrete: isDiscrete,
            vKind: guessType(data, drawSamples = false))

proc fillDiscreteColorScale(scKind: static ScaleKind, vKind: ValueKind, col: FormulaNode,
                            labelSeq: seq[Value]): Scale =
  result = Scale(scKind: scColor, vKind: vKind, col: col, dcKind: dcDiscrete)
  result.labelSeq = labelSeq
  result.valueMap = initOrderedTable[Value, ScaleValue]()
  let colorCs = ggColorHue(labelSeq.len)
  for i, k in result.labelSeq:
    # NOTE: workaround, since we cannot do `kind: sckind` atm
    result.valueMap[k] = if scKind == scColor:
                           ScaleValue(kind: scColor, color: colorCs[i])
                         else:
                           ScaleValue(kind: scFillColor, color: colorCs[i])

proc fillDiscreteSizeScale(vKind: ValueKind, col: FormulaNode,
                           labelSeq: seq[Value]): Scale =
  result = Scale(scKind: scSize, vKind: vKind, col: col, dcKind: dcDiscrete)
  result.labelSeq = labelSeq
  result.valueMap = initOrderedTable[Value, ScaleValue]()
  let numSizes = min(labelSeq.len, 5)
  const minSize = 2.0
  const maxSize = 7.0
  let stepSize = (maxSize - minSize) / numSizes.float
  for i, k in labelSeq:
    result.valueMap[k] = ScaleValue(kind: scSize, size: minSize + i.float * stepSize)

proc fillDiscreteLinearTransScale(
  scKind: static ScaleKind,
  col: FormulaNode,
  axKind: AxisKind,
  vKind: ValueKind, labelSeq: seq[Value],
  trans: Option[ScaleTransform] = none[ScaleTransform]()
     ): Scale =
  result = Scale(scKind: scKind, vKind: vKind, col: col, dcKind: dcDiscrete)
  result.labelSeq = labelSeq.sortedByIt(it)
  result.valueMap = initOrderedTable[Value, ScaleValue]()
  result.axKind = axKind
  if scKind == scTransformedData:
    ## we make  sure `trans` is some in the calling scope!
    result.trans = trans.get

proc fillContinuousLinearScale(col: FormulaNode, axKind: AxisKind, vKind: ValueKind,
                               dataScale: ginger.Scale): Scale =
  result = Scale(scKind: scLinearData, vKind: vKind, col: col, dcKind: dcContinuous,
                 dataScale: dataScale)
  result.axKind = axKind

proc fillContinuousTransformedScale(col: FormulaNode,
                                    axKind: AxisKind,
                                    vKind: ValueKind,
                                    trans: ScaleTransform,
                                    dataScale: ginger.Scale): Scale =
  result = Scale(scKind: scTransformedData, vKind: vKind, col: col,
                 dcKind: dcContinuous,
                 # apply transformation to data scale
                 dataScale: (low: trans(%~ dataScale.low).toFloat,
                             high: trans(%~ dataScale.high).toFloat))
  result.axKind = axKind
  result.trans = trans

proc fillContinuousColorScale(scKind: static ScaleKind,
                              col: FormulaNode,
                              vKind: ValueKind,
                              dataScale: ginger.Scale,
                              df: DataFrame): Scale =
  ## devise colormap mapping
  result = Scale(scKind: scKind, vKind: vKind, col: col, dcKind: dcContinuous,
                 dataScale: dataScale)
  # for now just take viridis as default
  # map all values to values between 0-255 and get the correct idx of viridis map
  result.mapData = (
    proc(idxsIn: seq[int] = @[]): seq[ScaleValue] =
      var idxs: seq[int]
      if idxsIn.len == 0: idxs = toSeq(0 .. df.high)
      else: idxs = idxsIn
      result = newSeq[ScaleValue](idxs.len)
      for i, idx in idxs:
        var colorIdx = (255.0 * ((col.evaluate(df, idx).toFloat - dataScale.low) /
                                 (dataScale.high - dataScale.low))).round.int
        colorIdx = min(255, colorIdx)
        let cVal = ViridisRaw[colorIdx]
        var scVal = if scKind == scColor:
                      ScaleValue(kind: scColor)
                    else:
                      ScaleValue(kind: scFillColor)
        scVal.color = color(cVal[0], cVal[1], cVal[2])
        result[i] = scVal
  )

proc fillContinuousSizeScale(col: FormulaNode, vKind: ValueKind,
                             dataScale: ginger.Scale,
                             df: DataFrame): Scale =
  const minSize = 2.0
  const maxSize = 7.0
  result = Scale(scKind: scSize, vKind: vKind, col: col, dcKind: dcContinuous,
                 dataScale: dataScale)
  result.mapData = (
    proc(idxsIn: seq[int] = @[]): seq[ScaleValue] =
      var idxs: seq[int]
      if idxsIn.len == 0: idxs = toSeq(0 .. df.high)
      else: idxs = idxsIn
      result = newSeq[ScaleValue](idxs.len)
      for i, idx in idxs:
        let size = (col.evaluate(df, idx).toFloat - minSize) /
                   (maxSize - minSize)
        result[i] = ScaleValue(kind: scSize,
                               size: size)
  )

proc fillScaleImpl(
  vKind: ValueKind,
  isDiscrete: bool,
  col: FormulaNode,
  df: DataFrame,
  scKind: static ScaleKind,
  labelSeqOpt: Option[seq[Value]] = none[seq[Value]](), # for discrete data
  dataScaleOpt: Option[ginger.Scale] = none[ginger.Scale](), # for cont data
  axKindOpt: Option[AxisKind] = none[AxisKind](),
  trans: Option[ScaleTransform] = none[ScaleTransform]()): Scale =
  ## fills the `Scale` of `scKind` kind of the `aes`
  ## TODO: make aware of Geom.data optional field!
  ## NOTE: The given `col` arg is not necessarily exactly a DF key anymore, since
  ## it might contain two or more columns as its basis
  # get the data column we scale by
  result = new Scale
  if isDiscrete:
    # convert to set to filter duplicates, back to seq and sort
    # TODO: we could also use `sequtils.deduplicate` here
    let labelSeq = labelSeqOpt.unwrap()
    case scKind
    of scColor:
      result = fillDiscreteColorScale(scColor, vKind, col, labelSeq)
    of scFillColor:
      result = fillDiscreteColorScale(scFillColor, vKind, col, labelSeq)
    of scSize:
      result = fillDiscreteSizeScale(vKind, col, labelSeq)
    of scLinearData:
      doAssert axKindOpt.isSome, "Linear data scales need an axis!"
      let axKind = axKindOpt.get
      result = fillDiscreteLinearTransScale(scLinearData, col,
                                            axKind, vKind, labelSeq)

    of scTransformedData:
      doAssert trans.isSome, "Transform data needs a ScaleTransform procedure!"
      doAssert axKindOpt.isSome, "Linear data scales need an axis!"
      let axKind = axKindOpt.get
      result = fillDiscreteLinearTransScale(scTransformedData, col,
                                            axKind, vKind, labelSeq,
                                            trans)
    of scShape:
      raise newException(ValueError, "Shape support not yet implemented for " &
        "discrete scales!")
  else:
    let dataScale = dataScaleOpt.unwrap()
    case scKind
    of scLinearData:
      doAssert axKindOpt.isSome, "Linear data scales need an axis!"
      let axKind = axKindOpt.get
      result = fillContinuousLinearScale(col, axKind, vKind, dataScale)
    of scTransformedData:
      doAssert trans.isSome, "Transform data needs a ScaleTransform procedure!"
      doAssert axKindOpt.isSome, "Linear data scales need an axis!"
      let axKind = axKindOpt.get
      result = fillContinuousTransformedScale(col, axKind, vKind, trans.get, dataScale)
    of scColor:
      result = fillContinuousColorScale(scColor, col, vKind, dataScale, df)
    of scFillColor:
      result = fillContinuousColorScale(scFillColor, col, vKind, dataScale, df)
    of scSize:
      result = fillContinuousSizeScale(col, vKind, dataScale, df)
    of scShape:
      raise newException(ValueError, "Shape not supported for continuous " &
        "variables!")

type
  ScaleData = tuple
    data: Option[DataFrame]
    scale: Scale
    statKind: StatKind

proc fillScale(df: DataFrame, scales: seq[Scale],
               scKind: static ScaleKind): seq[Scale] =
  # NOTE: `data` is used to build a seq of data of the given scales. Be aware
  # that all scales given here belong to the same `aes` field, i.e. the same
  # "axis" (x, y, color,...) and thus can be considered compatible and part of the
  # same scale / classes! The actual data given to each filled scale however is not
  # this DF, but rather the input `df.select(s.col)`, see below.
  var data = newSeqOfCap[Value](df.len * scales.len)
  var transOpt: Option[ScaleTransform]
  var axKindOpt: Option[AxisKind]
  # in a first loop over the scales read the data required to make decisions about
  # the appearence of the resulting scale
  for s in scales:
    # add this scales data to `data` DF for deduction of labels / data scales
    data.addIdentityData(df, s.col)
  # in the second loop for each of the scales add one filled scale to the result
  # using the combined dataset of all. This way we automatically get the correct
  # data range / correct number of labels while retaining a single scale per
  # geom.
  var dataScaleOpt: Option[ginger.Scale]
  var labelSeqOpt: Option[seq[Value]]
  var dcKindOpt: Option[DiscreteKind]
  for s in scales:
    # check if scale predefined discreteness
    if s.hasDiscreteness:
      dcKindOpt = some(s.dcKind)
    case scKind
    of scLinearData:
      axKindOpt = some(s.axKind)
    of scTransformedData:
      axKindOpt = some(s.axKind)
      # ## we use the last transformation we find!
      transOpt = some(s.trans)
    else: discard

    # now determine labels, data scale from `data`
    let (isDiscrete, vKind) = discreteAndType(data, dcKindOpt)
    if vKind == VNull:
      echo "WARNING: Unexpected data type VNull of column: ", s.col, "!"
      continue

    if isDiscrete:
      labelSeqOpt = some(data.deduplicate.sorted)
    else:
      dataScaleOpt = some(scaleFromData(data))
      #dataScaleOpt = some((low: colMin(data),
      #                     high: colMax(data)))

    # now have to call `fillScaleImpl` with this information
    var filled = fillScaleImpl(vKind, isDiscrete, s.col, df, scKind,
                               labelSeqOpt, dataScaleOpt,
                               axKindOpt, transOpt)
    if scKind in {scLinearData, scTransformedData}:
      filled.secondaryAxis = s.secondaryAxis
    filled.ids = s.ids
    result.add filled

proc callFillScale(pData: DataFrame, scales: seq[ScaleData],
                   scKind: static ScaleKind): seq[Scale] =
  ## `pData` corresponds to the DataFrame of the `GgPlot` object. This is ``only`` (!!)
  ## used, if:
  ## - current scale is ``not`` in `GgPlot.aes`
  ## - `geom` with this scale has ``no`` `data` field
  # handle those geoms separately, which have their own data
  let separateIdxs = toSeq(0 .. scales.high).filterIt(scales[it].data.isSome)
  var scalesToUse = newSeq[Scale]()
  for i, s in scales:
    if i notin separateIdxs:
      scalesToUse.add s.scale
  if scalesToUse.len > 0:
    var filled: seq[Scale]
    # If the first scale is transformed, the others are too. Transformed handled
    # here, because `collectScales` uses `scLinearData` for `x` and `y`
    case scalesToUse[0].scKind
    of scTransformedData:
      filled = fillScale(pData, scalesToUse, scTransformedData)
    else:
      filled = fillScale(pData, scalesToUse, scKind)
    for fs in filled:
      result.add fs
  # now separates
  for i in separateIdxs:
    var additional: seq[Scale]
    case scales[i].scale.scKind
    of scTransformedData:
      additional = fillScale(scales[i].data.get, @[scales[i].scale], scTransformedData)
    else:
      additional = fillScale(scales[i].data.get, @[scales[i].scale], scKind)
    doAssert additional.len <= 1
    for fs in additional:
      result.add fs

template collect(p: GgPlot, f: untyped): untyped =
  var sds = newSeq[ScaleData]()
  if isSome(p.aes.f):
    # NOTE: the dataframe of GgPlot is always given individually to
    # the fill* procs, hence we give a none here
    sds.add (data: none(DataFrame), scale: p.aes.f.get,
             statKind: stIdentity)
  for g in p.geoms:
    if isSome(g.aes.f):
      sds.add (data: g.data, scale: g.aes.f.get,
               statKind: g.statKind)
  sds

proc collectScales*(p: GgPlot): FilledScales =
  ## Collects all scales required to draw the plot. This means comparing each
  ## possible aesthetic scale of the `GgPlot p` itself with its geoms and
  ## building the final `Scale` for each.
  # TODO: clean up
  # if we either put `collect` as template in here or `fillField` as template
  # (even outside) we get undeclared identifier errors
  macro fillField(f: static string, arg: typed): untyped =
    let field = ident(f)
    let argId = ident(arg.strVal)
    result = quote do:
      if `argId`.len > 0 and `argId`[0].ids == {0'u16 .. high(uint16)}:
        result.`field` = (main: some(`argId`[0]), more: `argId`[1 .. ^1])
      else:
        result.`field` = (main: none[Scale](), more: `argId`)
  let xs = collect(p, x)
  # NOTE: transformed data handled from this in `callFillScale`!
  let xFilled = callFillScale(p.data, xs, scLinearData)
  fillField("x", xFilled)

  let xsMin = collect(p, xMin)
  let xMinFilled = callFillScale(p.data, xsMin, scLinearData)
  fillField("xMin", xMinFilled)

  let xsMax = collect(p, xMax)
  let xMaxFilled = callFillScale(p.data, xsMax, scLinearData)
  fillField("xMax", xMaxFilled)

  var ys = collect(p, y)
  # NOTE: transformed data handled from this in `callFillScale`!
  let yFilled = callFillScale(p.data, ys, scLinearData)
  fillField("y", yFilled)

  let ysMin = collect(p, yMin)
  let yMinFilled = callFillScale(p.data, ysMin, scLinearData)
  fillField("yMin", yMinFilled)

  let ysMax = collect(p, yMax)
  let yMaxFilled = callFillScale(p.data, ysMax, scLinearData)
  fillField("yMax", yMaxFilled)

  let colors = collect(p, color)
  let colorFilled = callFillScale(p.data, colors, scColor)
  fillField("color", colorFilled)
  let fills = collect(p, fill)
  let fillFilled = callFillScale(p.data, fills, scFillColor)
  fillField("fill", fillFilled)
  let sizes = collect(p, size)
  let sizeFilled = callFillScale(p.data, sizes, scSize)
  fillField("size", sizeFilled)
  let shapes = collect(p, shape)
  let shapeFilled = callFillScale(p.data, shapes, scShape)
  fillField("shape", shapeFilled)

  postProcessScales(result, p)