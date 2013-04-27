# This is the implementation of the JSON OT type.
#
# Spec is here: https://github.com/josephg/ShareJS/wiki/JSON-Operations

if WEB?
  text = exports.types.text2
else
  text = require './text'

json = {}

json.name = 'json'

json.create = -> null

json.checkValidOp = (op) ->

Array::isPrefixOf = (b) ->
  return false if @length > b.length
  for x,i in this
    return false unless b[i] is x
  true
# hax, copied from test/types/json. Apparently this is still the fastest way to deep clone an object, assuming
# we have browser support for JSON.
# http://jsperf.com/cloning-an-object/12
clone = (o) -> JSON.parse(JSON.stringify o)
isArray = (o) -> Object.prototype.toString.call(o) == '[object Array]'
isObject = (o) -> o.constructor is Object
init = (a) -> a[...a.length-1]
last = (a) -> a[a.length-1]
def = (x) -> typeof x != 'undefined'
merge = (a,b) ->
  f = {}
  for k,v of a
    f[k] = v unless k of b
  for k,v of b
    f[k] = v
  f
arrayEq = (a,b) ->
  return false unless a.length == b.length
  for x,i in a
    return false unless x == b[i]
  return true

ek = (container, p) ->
  elem = container
  key = 'data'

  for k in p
    elem = elem[key]
    key = k

  [elem, key]

json.apply = (snapshot, op) ->
  container = {data: clone snapshot}

  for c in op
    if typeof c['+'] != 'undefined'
      [elem, key] = ek(container, c.at)
      elem[key] += c['+']

    else if typeof c.s != 'undefined'
      [elem, key] = ek(container, c.at)
      elem[key] = text.apply elem[key], c.s

    else if typeof c.x != 'undefined'
      [elem, key] = ek(container, c.at)
      elem[key] = clone c.x

    else if typeof c.i != 'undefined'
      [elem, key] = ek(container, c.at)
      if typeof key is 'number'
        elem.splice key, 0, clone c.i
      else
        if key of elem
          util = require 'util'
          util.debug util.format '%j, %j', key, elem
          throw new Error "can't insert over existing key. use x instead."
        elem[key] = clone c.i

    else if c.d
      [elem, key] = ek(container, c.d)
      if typeof key is 'number'
        elem.splice key, 1
      else
        delete elem[key]

    else
      throw new Error 'invalid / missing instruction in op'

  container.data

json.append = (dest, c) ->
  dest.push c

json.compose = (op1, op2) ->
  # TODO: can probably get away with just slice() here.
  newOp = clone op1
  json.append newOp, c for c in op2

  newOp

json.normalize = (op) ->
  newOp = []
  
  op = [op] unless isArray op

  for c in op
    c.p ?= []
    json.append newOp, c
  
  newOp



################################################################
# TRANSFORM

updatePathForD = (p, op) ->
  return null if op.length is 0
  p = p[..]
  if init(op).isPrefixOf(p)
    if last(op) == p[op.length-1]
      return null
    else if typeof last(op) is 'number' and last(op) < p[op.length-1]
      p[op.length-1]--
  return p

updatePathForI = (p, op, meFirst) ->
  p = p[..]
  return p if typeof last(op) isnt 'number'
  if init(op).isPrefixOf(p)
    if last(op) == p[op.length-1]
      unless p.length == op.length and meFirst
        p[op.length-1]++
    else if last(op) < p[op.length-1]
      p[op.length-1]++
  return p

updatePathForM = (p, from, to) ->
  throw 'bad move' if from.length is 0 or to.length is 0
  p = p[..]
  return p if p.length is 0
  if from.isPrefixOf(p)
    p = to.concat p[from.length..]
  else
    if typeof last(to) isnt 'number' and to.isPrefixOf(p)
      return
    p = updatePathForD p, from
    return unless p?
    to = updatePathForD to, from
    p = updatePathForI p, to
  return p

updateLMForLM = (from, to, otherFrom, otherTo, type) ->
  fromP = from
  toP = to

  # step 1: where did my thing go?
  # they moved around it
  if from > otherFrom
    fromP--
  if from > otherTo
    fromP++
  else if from == otherTo
    if otherFrom > otherTo
      fromP++
      if from == to # ugh, again
        toP++

  # step 2: where am i going to put it?
  if to > otherFrom
    toP--
  else if to == otherFrom
    if to > from
      toP--
  if to > otherTo
    toP++
  else if to == otherTo
    # if we're both moving in the same direction, tie break
    if (otherTo > otherFrom and to > from) or
       (otherTo < otherFrom and to < from)
      if type == 'right'
        toP++
    else
      if to > from
        toP++
      else if to == otherFrom
        toP--
  return {from:fromP, to:toP}

# ops are: s,+,d,i,x,m. 36 cases, 12 trivial = 24.
transform = (c, oc, type) ->
  if def(oc['+'])
    # this is the easy one
    return clone c
  else if def(oc.s)
    # subop
    if def(c.s) and arrayEq c.at, oc.at
      return {at:c.at, s:text.transform c.s, oc.s, type}
    return clone c

  if oc.d
    switch
      when c.at # i, s, +, x
        # i and d at the same place --> i carries on
        if def(c.i) and arrayEq c.at, oc.d
          return c
        p = updatePathForD c.at, oc.d
        if p?
          return merge(c,{at:p})
      when c.d
        if arrayEq c.d, oc.d
          return undefined
        else
          p = updatePathForD c.d, oc.d
          if p?
            return {d:p}
      when def(c.m)
        # if i try to move something but it got deleted, there's nothing left
        # to move.
        from = updatePathForD c.m, oc.d
        if from?
          to = updatePathForD c.to, oc.d
          if to?
            return {m:from,to}
  else if def(oc.i)
    switch
      when def c.i
        if typeof last(oc.at) isnt 'number' and arrayEq(c.at, oc.at)
          if type is 'left'
            return {x:c.i,at:c.at}
          else
            return undefined
        p = updatePathForI c.at, oc.at, type is 'left'
        return merge(c,{at:p})
      when c.at # s, +, x
        p = updatePathForI c.at, oc.at
        return merge(c,{at:p})
      when c.d
        p = updatePathForI c.d, oc.at
        return {d:p}
      when def(c.m)
        from = updatePathForI c.m, oc.at
        to = updatePathForI c.to, oc.at
        return {m:from, to}
  else if def(oc.x)
    switch
      when typeof c.x != 'undefined'
        if arrayEq c.at, oc.at
          # two clients replacing the same thing
          if type is 'left'
            return clone c
          else
            return clone oc
        else
          p = updatePathForD c.at, oc.at
          if p?
            return c
      when c.at # i, s, +, x
        if def(c.i) and arrayEq c.at, oc.at
          return c
        p = updatePathForD c.at, oc.at
        if p?
          return c
      when c.d
        if arrayEq c.d, oc.at
          # delete wins
          return c
        p = updatePathForD c.d, oc.at
        if p?
          return c
      when def(c.m)
        from = updatePathForD c.m, oc.at
        if from?
          to = updatePathForD c.to, oc.at
          if to?
            return c
          else
            return {d:c.m}
  else if def(oc.m)
    return c if arrayEq oc.m, oc.to
    switch
      when def c.i
        if typeof last(c.at) is 'number'
          p = c.at[..]
          if oc.m.isPrefixOf init(p)
            p = oc.to.concat p[oc.m.length..]
          else
            if arrayEq init(c.at), init(oc.m)
              if last(oc.m) < last(c.at)
                p[p.length-1]--
            if arrayEq init(c.at), init(oc.to)
              if last(oc.to) < last(c.at)
                p[p.length-1]++
          return {i:c.i,at:p}
        else
          p = updatePathForM c.at, oc.m, oc.to
          if p?
            return {i:c.i,at:p}
      when c.at # s, +, x
        p = updatePathForM c.at, oc.m, oc.to
        if p
          return merge c, {at:p}
      when c.d
        p = updatePathForM c.d, oc.m, oc.to
        if p?
          return {d:p}
      when def c.m
        if arrayEq c.m, oc.m
          if type is 'left'
            return {m:oc.to,to:c.to}
          else
            return

        if typeof last(c.m) is 'number' and arrayEq(init(c.m), init(c.to)) and arrayEq(init(c.m), init(oc.m)) and arrayEq(init(c.m), init(oc.to))
          # both c and oc are operating in the same array. lm vs lm, here we go.
          {from, to} = updateLMForLM last(c.m), last(c.to), last(oc.m), last(oc.to), type
          return {m:init(c.m).concat([from]), to:init(c.to).concat([to])}

        if typeof last(c.to) isnt 'number'
          if arrayEq(c.to, oc.to)
            # both moving to the same key in an object, tie-break.
            from = updatePathForM c.m, oc.m, oc.to
            return unless from?
            if type is 'left' or c.to.isPrefixOf oc.m
              # my op wins
              return {m:from,to:c.to}
            else
              return {d:from}
          else if arrayEq(c.m, oc.to)
            if arrayEq(c.to, oc.m)
              # a swap collides; neither side has enough info to reconstruct.
              return {d:c.m}


        from = updatePathForM c.m, oc.m, oc.to
        to = updatePathForM c.to, oc.m, oc.to
        if from and to
          return {m:from,to}

json.transformComponent = (dest, c, otherC, type) ->
  c_ = transform c, otherC, type
  if c_?
    json.append dest, clone c_

  util = require 'util'
  util.debug util.format '%j against %j (%s) gives %j', c, otherC, type, c_
  return dest


#################################################################


if WEB?
  exports.types ||= {}

  # This is kind of awful - come up with a better way to hook this helper code up.
  exports._bt(json, json.transformComponent, json.checkValidOp, json.append)

  # [] is used to prevent closure from renaming types.text
  exports.types.json = json
else
  module.exports = json

  require('./helpers').bootstrapTransform(json, json.transformComponent, json.checkValidOp, json.append)