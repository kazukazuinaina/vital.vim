" Java Stream API like streaming library

let s:save_cpo = &cpo
set cpo&vim

" ============= Design of Internal API =============
"
" * a stream works like queue.
"   __take_possible__(n) takes n or less elements from queue.
"
" * __take_possible__(n)
"   * n must be 0 or positive
"     * in order to take all elements from the stream, pass 1/0 (:help expr-/)
"   * this function returns '[list, open]'
"     * 'len(list) <= n'
"     * caller must not invoke this function after 'open == 0' is returned
" * `__estimate_size__()`
"   * this function must not change stream's state
"   * if the number of elements is 'unknown', 1/0 is returned
"     * 'flat_map()' cannot determine the number of elements of the result
"     * 'Stream.of(0,1,2,3).flat_map({n -> repeat([n], n)}).to_list() == [1,2,2,3,3,3]'
"     * 'Stream.of(0,1,2,3).flat_map({n -> repeat([n], n)}).__estimate_size__() == 1/0'
"   * if the stream is finite stream ('self.__has_characteristic__(s:SIZED) == 1'),
"     returns the number of elements
"   * if the stream is infinite stream ('self.__has_characteristic__(s:SIZED) == 0'),
"     returns 1/0
"

let s:NONE = []
lockvar! s:NONE

let s:T_NUMBER = 0
let s:T_STRING = 1
let s:T_FUNC = 2
let s:T_LIST = 3
let s:T_DICT = 4
let s:T_FLOAT = 5
let s:T_BOOL = 6
let s:T_NONE = 7
let s:T_JOB = 8
let s:T_CHANNEL = 9

" let s:ORDERED = 0x01
" let s:DISTINCT = 0x02
" let s:SORTED = 0x04
let s:SIZED = 0x08
" let s:NONNULL = 0x10
" let s:IMMUTABLE = 0x20
" let s:CONCURRENT = 0x40

function! s:_vital_loaded(V) abort
  let validator = a:V.import('Validator.Args')
  let T = validator.TYPE
  let s:chars_args = validator.of('vital: Stream: chars()').type(T.STRING)
  let s:lines_args = validator.of('vital: Stream: lines()').type(T.STRING)
  let s:from_list_args = validator.of('vital: Stream: from_list()').type(T.LIST)
  let s:from_dict_args = validator.of('vital: Stream: from_dict()').type(T.DICT)
  let s:range_args = validator.of('vital: Stream: range()')
                             \.type(T.NUMBER, T.OPTARG, T.NUMBER, T.NUMBER)
                             \.assert(3, 'v:val !=# 0', 'stride is zero')
  let s:iterate_args = validator.of('vital: Stream: iterate()')
                               \.type(T.ANY, T.FUNC)
  let s:generate_args = validator.of('vital: Stream: generate()')
                                \.type(T.FUNC)
  let s:generator_args = validator.of('vital: Stream: generator()')
                          \.type(T.DICT)
                          \.assert(1, 'type(get(v:val, ''yield'', 0)) is '.s:T_FUNC,
                          \        'the first argument should have ''yield'' method')
  let s:zip_args = validator.of('vital: Stream: zip()')
                           \.type(T.LIST)
                           \.assert(1,
                           \ function('s:_is_list_of_streams'),
                           \ 'the first argument should be a list of streams')
  let s:concat_args = validator.of('vital: Stream: concat()')
                              \.type(T.LIST)
                              \.assert(1,
                              \ function('s:_is_list_of_streams'),
                              \ 'the first argument should be a list of streams')
  let s:peek_args = validator.of('vital: Stream: Stream.peek()')
                            \.type(T.FUNC)
  let s:map_args = validator.of('vital: Stream: Stream.map()')
                           \.type(T.FUNC)
  let s:flat_map_args = validator.of('vital: Stream: Stream.flat_map()')
                                \.type(T.FUNC)
  let s:filter_args = validator.of('vital: Stream: Stream.filter()')
                              \.type(T.FUNC)
  let s:slice_before_args = validator.of('vital: Stream: Stream.slice_before()')
                                    \.type(T.FUNC)
  let s:take_while_args = validator.of('vital: Stream: Stream.take_while()')
                                  \.type(T.FUNC)
  let s:drop_while_args = validator.of('vital: Stream: Stream.drop_while()')
                                  \.type(T.FUNC)
  let s:distinct_args = validator.of('vital: Stream: Stream.distinct()')
                                \.type(T.OPTARG, T.FUNC)
  let s:sorted_args = validator.of('vital: Stream: Stream.sorted()')
                              \.type(T.OPTARG, T.FUNC)
  let s:take_args = validator.of('vital: Stream: Stream.take()')
                            \.type(T.NUMBER)
                            \.assert(1, 'v:val >= 0',
                            \ 'the first argument must be 0 or positive')
  let s:drop_args = validator.of('vital: Stream: Stream.drop()')
                            \.type(T.NUMBER)
                            \.assert(1, 'v:val >= 0',
                            \ 'the first argument must be 0 or positive')
  let s:reduce_args = validator.of('vital: Stream: Stream.reduce()')
                              \.type(T.FUNC, T.OPTARG, T.ANY)
  let s:find_args = validator.of('vital: Stream: Stream.find()')
                            \.type(T.FUNC, T.OPTARG, T.ANY)
  let s:any_args = validator.of('vital: Stream: Stream.any()')
                           \.type(T.FUNC)
  let s:all_args = validator.of('vital: Stream: Stream.all()')
                           \.type(T.FUNC)
  let s:none_args = validator.of('vital: Stream: Stream.none()')
                            \.type(T.FUNC)
  let s:group_by_args = validator.of('vital: Stream: Stream.group_by()')
                                \.type(T.FUNC)
  let s:to_dict_args = validator.of('vital: Stream: Stream.to_dict()')
                               \.type(T.FUNC, T.FUNC, T.OPTARG, T.FUNC)
  let s:count_args = validator.of('vital: Stream: Stream.count()')
                             \.type(T.OPTARG, T.FUNC)
  let s:foreach_args = validator.of('vital: Stream: Stream.foreach()')
                               \.type(T.FUNC)
endfunction

function! s:_vital_depends() abort
  return ['Validator.Args']
endfunction


function! s:of(elem, ...) abort
  return s:_new_from_list([a:elem] + a:000, s:SIZED, 'of()')
endfunction

function! s:chars(...) abort
  let [str] = s:chars_args.validate(a:000)
  return s:_new_from_list(split(str, '\zs'), s:SIZED, 'chars()')
endfunction

function! s:lines(...) abort
  let [str] = s:lines_args.validate(a:000)
  let lines = str ==# '' ? [] : split(str, '\r\?\n', 1)
  return s:_new_from_list(lines, s:SIZED, 'lines()')
endfunction

function! s:from_list(...) abort
  let [list] = s:from_list_args.validate(a:000)
  return s:_new_from_list(copy(list), s:SIZED, 'from_list()')
endfunction

function! s:from_dict(...) abort
  let [dict] = s:from_dict_args.validate(a:000)
  let list = map(items(dict), '{''key'': v:val[0], ''value'': v:val[1]}')
  return s:_new_from_list(list, s:SIZED, 'from_dict()')
endfunction

function! s:empty() abort
  return s:_new_from_list([], s:SIZED, 'empty()')
endfunction

function! s:_new_from_list(list, characteristics, caller) abort
  let stream = s:_new(s:Stream)
  let stream._name = a:caller
  let stream._characteristics = a:characteristics
  let stream.__index = 0
  let stream._list = a:list
  function! stream.__take_possible__(n) abort
    " fix overflow
    let n = self.__index + a:n < a:n ? 1/0 : self.__index + a:n
    let list = s:_sublist(self._list, self.__index, n - 1)
    let self.__index = n
    return [list, self.__estimate_size__() > 0]
  endfunction
  function! stream.__estimate_size__() abort
    return max([len(self._list) - self.__index, 0])
  endfunction
  return stream
endfunction

" same arguments as Vim script's range()
function! s:range(...) abort
  let [expr; rest] = s:range_args.validate(a:000)
  if len(rest) ==# 0
    let args = [0, expr - 1, 1]
  elseif len(rest) ==# 1
    let args = [expr, rest[0], 1]
  else
    let args = [expr, rest[0], rest[1]]
  endif
  if s:_range_size(args, 0) ==# 0
    return s:empty()
  endif
  let stream = s:_new(s:Stream)
  let stream._name = 'range()'
  let stream._characteristics = s:SIZED
  let stream.__index = 0
  let stream._args = args
  function! stream.__take_possible__(n) abort
    if a:n ==# 0
      return [[], 1]
    endif
    " workaround for E727 error when the second argument is too big (e.g.: 1/0)
    " a_i = a0 + (n - 1) * a2
    let args = copy(self._args)
    if args[1] >= a:n
      let args[1] = args[0] + (a:n - 1) * args[2]
    endif
    " 'call(...)' is non-empty and 's:_sublist(...)' is also non-empty
    " assert a:n != 0
    let list = s:_sublist(call('range', args), self.__index, self.__index + a:n - 1)
    let self.__index += a:n
    return [list, self.__estimate_size__() > 0]
  endfunction
  function! stream.__estimate_size__() abort
    return s:_range_size(self._args, self.__index)
  endfunction
  return stream
endfunction

" a0 <= a1, a2 > 0, a_0 = a0, i >= 0
" a_i = a0 + i * a2
" size([a0,a1,a2],i) = (a1 - a_i) / a2 + 1
"                    = (a1 - a0) / a2 - i + 1
"
" @assert a:args[2] != 0
" @assert len(a:args) >= 3
" @assert a:index >= 0
function! s:_range_size(args, index) abort
  let [a0, a1, a2] = a:args
  if a2 < 0
    return s:_range_size([a1, a0, -a2], a:index)
  elseif a0 > a1
    return 0
  else
    " if a:index exceeds range, it becomes 0 or negative
    return max([(a1 - a0) / a2 - a:index + 1, 0])
  endif
endfunction

function! s:iterate(...) abort
  let [l:Init, l:Func] = s:iterate_args.validate(a:000)
  return s:_inf_stream(
  \ l:Func, l:Init, 'self._f(v:val)', 'iterate()'
  \)
endfunction

function! s:generate(...) abort
  let [l:Func] = s:generate_args.validate(a:000)
  return s:_inf_stream(
  \ l:Func, l:Func(), 'self._f()', 'generate()')
endfunction

function! s:_inf_stream(f, init, expr, caller) abort
  let stream = s:_new(s:Stream)
  let stream._name = a:caller
  let stream._characteristics = 0
  let stream._f = a:f
  let stream.__value = a:init
  let stream._expr = a:expr
  function! stream.__take_possible__(n) abort
    let list = []
    let i = 0
    while i < a:n
      let list += [self.__value]
      let self.__value = map([self.__value], self._expr)[0]
      let i += 1
    endwhile
    return [list, 1]
  endfunction
  function! stream.__estimate_size__() abort
    return 1/0
  endfunction
  return stream
endfunction

function! s:generator(...) abort
  let [dict] = s:generator_args.validate(a:000)
  let stream = s:_new(s:Stream)
  let stream._name = 'generator()'
  let stream._characteristics = 0
  let stream._dict = dict
  let stream.__index = 0
  function! stream.__take_possible__(n) abort
    let list = []
    let i = 0
    let open = 1
    while i < a:n
      let l:Value = self._dict.yield(i + self.__index, s:NONE)
      if l:Value is s:NONE
        let open = 0
        break
      endif
      let list += [l:Value]
      let i += 1
      unlet l:Value
    endwhile
    let self.__index += i
    return [list, open]
  endfunction
  function! stream.__estimate_size__() abort
    return 1/0
  endfunction
  return stream
endfunction

function! s:zip(...) abort
  let [streams] = s:zip_args.validate(a:000)
  if empty(streams)
    return s:empty()
  endif
  let stream = s:_new(s:Stream)
  let stream._name = 'zip()'
  let stream._characteristics =
  \ s:_zip_characteristics(map(copy(streams), 'v:val._characteristics'))
  let stream._upstream = streams
  function! stream.__take_possible__(n) abort
    let lists = map(copy(self._upstream),
    \               's:_take_freeze_intermediate(v:val, a:n)[0]')
    let smaller = min(map(copy(lists), 'len(v:val)'))
    " lists = [[1,2,3], [4,5,6]], list = [[1,4], [2,5], [3,6]]
    " let list = map(range(smaller), '[lists[0][v:val], lists[1][v:val], ...]')
    let expr = '[' . join(map(range(len(lists)), '''lists['' . v:val . ''][v:val]'''), ',') . ']'
    let list = map(range(smaller), expr)
    return [list, self.__estimate_size__() > 0]
  endfunction
  function! stream.__estimate_size__() abort
    return min(map(copy(self._upstream), 'v:val.__estimate_size__()'))
  endfunction
  return stream
endfunction

function! s:_zip_characteristics(characteristics_list) abort
  if len(a:characteristics_list) <= 1
    return a:characteristics_list[0]
  endif
  " or() for SIZED flag. and() for other flags
  let [c1, c2; others] = a:characteristics_list
  let result = or(and(c1, c2), and(or(c1, c2), s:SIZED))
  return s:_zip_characteristics([result] + others)
endfunction

function! s:concat(...) abort
  let [streams] = s:concat_args.validate(a:000)
  let nonempty = filter(copy(streams), 'v:val.__estimate_size__() > 0')
  let stream = s:_new(s:Stream)
  let stream._name = 'concat()'
  let stream._characteristics =
  \ s:_concat_characteristics(map(copy(nonempty), 'v:val._characteristics'))
  let stream._upstream = nonempty
  function! stream.__take_possible__(n) abort
    " concat buffer and all streams
    let list = []
    for stream in self._upstream
      if len(list) >= a:n
        break
      endif
      if stream.__estimate_size__() > 0
        let list += s:_take_freeze_intermediate(stream, a:n - len(list))[0]
      endif
    endfor
    " if all of buffer length, streams' __estimate_size__() are 0,
    " it is end of streams
    let sizes = map(copy(self._upstream), 'v:val.__estimate_size__()')
    return [list, max(sizes) > 0]
  endfunction
  if and(stream._characteristics, s:SIZED)
    function! stream.__estimate_size__() abort
      let sizes = map(copy(self._upstream), 'v:val.__estimate_size__()')
      return self.__sum__(sizes)
    endfunction
    " 1/0 when overflow
    function! stream.__sum__(sizes) abort
      if len(a:sizes) <= 1
        return a:sizes[0]
      else
        let [size1, size2; others] = a:sizes
        return size1 + size2 >= size1 ?
        \         self.__sum__([size1 + size2] + others) : 1/0
      endif
    endfunction
  else
    function! stream.__estimate_size__() abort
      return 1/0
    endfunction
  endif
  return stream
endfunction

function! s:_concat_characteristics(characteristics_list) abort
  if len(a:characteristics_list) <= 1
    return a:characteristics_list[0]
  endif
  " and() for all flags
  let [c1, c2; others] = a:characteristics_list
  return s:_concat_characteristics([and(c1, c2)] + others)
endfunction


let s:Stream = {}

function! s:Stream.__has_characteristic__(flag) abort
  return !!and(self._characteristics, a:flag)
endfunction

function! s:Stream.peek(...) abort
  call s:_validate_closed_stream(self)
  let [l:Func] = s:peek_args.validate(a:000)
  let stream = s:_new(s:Stream)
  let stream._name = 'Stream.peek()'
  let stream._characteristics = self._characteristics
  let stream._upstream = self
  let stream._f = l:Func
  function! stream.__take_possible__(n) abort
    let list = s:_take_freeze_intermediate(self._upstream, a:n)[0]
    call map(copy(list), 'self._f(v:val)')
    return [list, self.__estimate_size__() > 0]
  endfunction
  function! stream.__estimate_size__() abort
    return self._upstream.__estimate_size__()
  endfunction
  return stream
endfunction

function! s:Stream.map(...) abort
  call s:_validate_closed_stream(self)
  let [l:Func] = s:map_args.validate(a:000)
  let stream = s:_new(s:Stream)
  let stream._name = 'Stream.map()'
  let stream._characteristics = self._characteristics
  let stream._upstream = self
  let stream._f = l:Func
  function! stream.__take_possible__(n) abort
    let list = s:_take_freeze_intermediate(self._upstream, a:n)[0]
    call map(list, 'self._f(v:val)')
    return [list, self.__estimate_size__() > 0]
  endfunction
  function! stream.__estimate_size__() abort
    return self._upstream.__estimate_size__()
  endfunction
  return stream
endfunction

function! s:Stream.flat_map(...) abort
  call s:_validate_closed_stream(self)
  let [l:Func] = s:flat_map_args.validate(a:000)
  let stream = s:_new(s:Stream, s:WithBuffered)
  let stream._name = 'Stream.flat_map()'
  let stream._characteristics = self._characteristics
  let stream._upstream = self
  let stream._f = l:Func
  function! stream.__take_possible__(n) abort
    let open = (self._upstream.__estimate_size__() > 0)
    if a:n ==# 0
      return [[], open]
    endif
    let list = []
    while open && len(list) < a:n
      let open = self.__read_to_buffer__(a:n)
      let r = s:_sublist(self.__buffer, 0, a:n - 1)
      let self.__buffer = s:_sublist(self.__buffer, a:n)
      " add results to list. len(l) <= a:n when the loop is end
      for l in map(r, 'self._f(v:val)')
        if len(l) + len(list) < a:n
          let list += l
        else
          let end = a:n - len(list)
          let list += s:_sublist(l, 0, end - 1)
          let self.__buffer = s:_sublist(l, end) + self.__buffer
          break
        endif
      endfor
    endwhile
    return [list, open]
  endfunction
  " the number of elements in stream is unknown (decreased, as-is, or increased)
  function! stream.__estimate_size__() abort
    return 1/0
  endfunction
  return stream
endfunction

function! s:Stream.filter(...) abort
  call s:_validate_closed_stream(self)
  let [l:Func] = s:filter_args.validate(a:000)
  let stream = s:_new(s:Stream)
  let stream._name = 'Stream.filter()'
  let stream._characteristics = self._characteristics
  let stream._upstream = self
  let stream._f = l:Func
  function! stream.__take_possible__(n) abort
    let [r, open] = s:_take_freeze_intermediate(self._upstream, a:n)
    let list = filter(r, 'self._f(v:val)')
    while open && len(list) < a:n
      let [r, open] = s:_take_freeze_intermediate(self._upstream, a:n - len(list))
      let list += filter(r, 'self._f(v:val)')
    endwhile
    return [list, open]
  endfunction
  function! stream.__estimate_size__() abort
    return self._upstream.__estimate_size__()
  endfunction
  return stream
endfunction

function! s:Stream.slice_before(...) abort
  call s:_validate_closed_stream(self)
  let [l:Func] = s:slice_before_args.validate(a:000)
  let stream = s:_new(s:Stream, s:WithBuffered)
  let stream._name = 'Stream.slice_before()'
  let stream._characteristics = self._characteristics
  let stream._upstream = self
  let stream._f = l:Func
  function! stream.__take_possible__(n) abort
    let open = (self._upstream.__estimate_size__() > 0)
    if a:n ==# 0
      return [[], open]
    endif
    let open = self.__read_to_buffer__(a:n)
    if empty(self.__buffer)
      return [[], open]
    endif
    let list = []
    let elem = [self.__buffer[0]]
    let self.__buffer = self.__buffer[1:]
    let do_break = 0
    while open
      let open = self.__read_to_buffer__(a:n - len(list))
      for i in range(len(self.__buffer))
        if self._f(self.__buffer[i])
          let list += [elem]
          if len(list) >= a:n
            let self.__buffer = s:_sublist(self.__buffer, i)
            let do_break = 1
            break
          endif
          let elem = [self.__buffer[i]]
        else
          let elem += [self.__buffer[i]]
        endif
      endfor
      if !open && len(list) < a:n
        let list += [elem]
      endif
      if do_break
        break
      endif
      let self.__buffer = []
    endwhile
    return [list, open]
  endfunction
  " the number of elements in stream is unknown (decreased, as-is, or increased)
  function! stream.__estimate_size__() abort
    return 1/0
  endfunction
  return stream
endfunction

" __take_possible__(n): n may be 1/0, so when upstream is infinite stream,
" 'self._upstream.__take_possible__(n)' does not stop
" unless .take(n) was specified in downstream.
" But regardless of whether .take(n) was specified,
" this method must stop for even upstream is infinite stream
" if 'a:f' is not matched at any element in the stream.
let s:BULK_SIZE = 32
function! s:Stream.take_while(...) abort
  call s:_validate_closed_stream(self)
  let [l:Func] = s:take_while_args.validate(a:000)
  let stream = s:_new(s:Stream)
  let stream._name = 'Stream.take_while()'
  let stream._characteristics = self._characteristics
  let stream._upstream = self
  let stream._f = l:Func
  function! stream.__take_possible__(n) abort
    let open = (self._upstream.__estimate_size__() > 0)
    if a:n ==# 0
      return [[], open]
    endif
    let do_break = 0
    let list = []
    while !do_break
      let [r, open] = s:_take_freeze_intermediate(self._upstream, s:BULK_SIZE)
      for l:Value in r
        if !map([l:Value], 'self._f(v:val)')[0]
          let open = 0
          let do_break = 1
          break
        endif
        let list += [l:Value]
        if len(list) >= a:n
          " requested number of elements was obtained,
          " but this stream is not closed for next call
          let do_break = 1
          break
        endif
        unlet l:Value
      endfor
      if !open
        break
      endif
    endwhile
    return [list, open]
  endfunction
  if self.__has_characteristic__(s:SIZED)
    function! stream.__estimate_size__() abort
      return self._upstream.__estimate_size__()
    endfunction
  else
    function! stream.__estimate_size__() abort
      return 1/0
    endfunction
  endif
  return stream
endfunction

function! s:Stream.drop_while(...) abort
  call s:_validate_closed_stream(self)
  let [l:Func] = s:drop_while_args.validate(a:000)
  let stream = s:_new(s:Stream)
  let stream._name = 'Stream.drop_while()'
  let stream._characteristics = self._characteristics
  let stream._upstream = self
  let stream.__skipping = 1
  let stream._f = l:Func
  function! stream.__take_possible__(n) abort
    let list = []
    let open = (self.__estimate_size__() > 0)
    while self.__skipping && open
      let [r, open] = s:_take_freeze_intermediate(self._upstream, a:n)
      for i in range(len(r))
        if !map([r[i]], 'self._f(v:val)')[0]
          let self.__skipping = 0
          let list = s:_sublist(r, i)
          break
        endif
      endfor
    endwhile
    if !self.__skipping && open && len(list) < a:n
      let [r, open] = s:_take_freeze_intermediate(self._upstream, a:n - len(list))
      let list += r
    endif
    return [list, open]
  endfunction
  if self.__has_characteristic__(s:SIZED)
    function! stream.__estimate_size__() abort
      return self._upstream.__estimate_size__()
    endfunction
  else
    function! stream.__estimate_size__() abort
      return 1/0
    endfunction
  endif
  return stream
endfunction

function! s:Stream.distinct(...) abort
  call s:_validate_closed_stream(self)
  let args = s:distinct_args.validate(a:000)
  let stream = s:_new(s:Stream)
  let stream._name = 'Stream.distinct()'
  let stream._characteristics = self._characteristics
  let stream._upstream = self
  if !empty(args)
    let stream._hashfunc = args[0]
  else
    let stream._hashfunc = function('string')
  endif
  function! stream.__take_possible__(n) abort
    let uniq_list = []
    let open = (self._upstream.__estimate_size__() > 0)
    let dup = {}
    while open && len(uniq_list) < a:n
      let [r, open] = s:_take_freeze_intermediate(
      \                   self._upstream, a:n - len(uniq_list))
      for l:Value in r
        let key = self._hashfunc(l:Value)
        if !has_key(dup, key)
          let uniq_list += [l:Value]
          if len(uniq_list) >= a:n
            let open = 0
            break
          endif
          let dup[key] = 1
        endif
        unlet l:Value
      endfor
    endwhile
    return [uniq_list, open]
  endfunction
  function! stream.__estimate_size__() abort
    return self._upstream.__estimate_size__()
  endfunction
  return stream
endfunction

function! s:Stream.sorted(...) abort
  call s:_validate_closed_stream(self)
  let args = s:sorted_args.validate(a:000)
  let stream = s:_new(s:Stream)
  let stream._name = 'Stream.sorted()'
  let stream._characteristics = self._characteristics
  let stream._upstream = self
  " if this key doesn't exist,
  " sorted list of upstream elements will be set (first time only)
  " let stream.__sorted_list = []
  if !empty(args)
    let stream._comparator = args[0]
  endif
  function! stream.__take_possible__(n) abort
    if !has_key(self, '__sorted_list')
      let self.__sorted_list = s:_take_freeze_intermediate(self._upstream, 1/0)[0]
      if has_key(self, '_comparator')
        call sort(self.__sorted_list, self.__compare__, self)
      else
        call sort(self.__sorted_list)
      endif
    endif
    let list = s:_sublist(self.__sorted_list, 0, a:n - 1)
    let self.__sorted_list = s:_sublist(self.__sorted_list, a:n)
    return [list, self.__estimate_size__() > 0]
  endfunction
  function! stream.__compare__(a, b) abort
    return self._comparator(a:a, a:b)
  endfunction
  function! stream.__estimate_size__() abort
    if has_key(self, '__sorted_list')
      return len(self.__sorted_list)
    endif
    return self._upstream.__estimate_size__()
  endfunction
  return stream
endfunction

function! s:Stream.take(...) abort
  call s:_validate_closed_stream(self)
  let [n] = s:take_args.validate(a:000)
  if n ==# 0
    return s:empty()
  endif
  let stream = s:_new(s:Stream)
  let stream._name = 'take()'
  let stream._characteristics = or(self._characteristics, s:SIZED)
  let stream._upstream = self
  let stream.__took_count = 0
  let stream._max_n = n
  function! stream.__take_possible__(n) abort
    let n = min([self._upstream.__estimate_size__(), self._max_n, a:n])
    let [list, open] = s:_take_freeze_intermediate(self._upstream, n)
    let self.__took_count += len(list)
    return [list, open && self.__took_count < min([self._max_n, a:n])]
  endfunction
  function! stream.__estimate_size__() abort
    return min([self._max_n - self.__took_count, self._upstream.__estimate_size__()])
  endfunction
  return stream
endfunction

function! s:Stream.drop(...) abort
  call s:_validate_closed_stream(self)
  let [n] = s:drop_args.validate(a:000)
  if n ==# 0
    return self
  endif
  let stream = s:_new(s:Stream)
  let stream._name = 'drop()'
  let stream._characteristics = self._characteristics
  let stream._upstream = self
  let stream.__n = n
  function! stream.__take_possible__(n) abort
    let open = self.__estimate_size__() > 0
    if self.__n > 0 && open
      let open = s:_take_freeze_intermediate(self._upstream, self.__n)[1]
      let self.__n = 0
    endif
    let list = []
    if self.__n ==# 0
      let [list, open] = s:_take_freeze_intermediate(self._upstream, a:n)
    endif
    return [list, open]
  endfunction
  if self.__has_characteristic__(s:SIZED)
    function! stream.__estimate_size__() abort
      return max([self._upstream.__estimate_size__() - self.__n, 0])
    endfunction
  else
    function! stream.__estimate_size__() abort
      return 1/0
    endfunction
  endif
  return stream
endfunction

function! s:Stream.zip(streams) abort
  call s:_validate_closed_stream(self)
  let streams = type(a:streams) is s:T_LIST ? a:streams : [s:NONE]
  return s:zip([self] + streams)
endfunction

function! s:Stream.zip_with_index() abort
  return s:zip([s:iterate(0, function('s:_succ')), self])
endfunction

function! s:_succ(n) abort
  return a:n + 1
endfunction

function! s:Stream.concat(streams) abort
  call s:_validate_closed_stream(self)
  let streams = type(a:streams) is s:T_LIST ? a:streams : [s:NONE]
  return s:concat([self] + streams)
endfunction

function! s:Stream.reduce(...) abort
  let [l:Func; rest] = s:reduce_args.validate(a:000)
  let list = self.to_list()
  if empty(rest) && empty(list)
    throw 'vital: Stream: Stream.reduce()' .
    \     ': stream is empty and default value was not given'
  endif
  if !empty(rest) || empty(list)
    let l:Result = rest[0]
  else
    let l:Result = list[0]
    let list = list[1:]
  endif
  for l:Value in list
    let l:Result = l:Func(l:Result, l:Value)
    unlet l:Value
  endfor
  return l:Result
endfunction

function! s:Stream.first(...) abort
  return s:_get_non_empty_list_or_default(
  \ self, 1, a:0 ? [a:1] : s:NONE, 'Stream.first()')[0]
endfunction

function! s:Stream.last(...) abort
  return s:_get_non_empty_list_or_default(
  \ self, self.__estimate_size__(), a:0 ? [a:1] : s:NONE, 'Stream.last()')[-1]
endfunction

function! s:Stream.find(...) abort
  let [l:Func; rest] = s:find_args.validate(a:000)
  let s = self.filter(l:Func)
  return !empty(rest) ? s.first(rest[0]) : s.first()
endfunction

function! s:Stream.any(...) abort
  let [l:Func] = s:any_args.validate(a:000)
  return self.filter(l:Func).first(s:NONE) isnot s:NONE
endfunction

function! s:Stream.all(...) abort
  let [l:Func] = s:all_args.validate(a:000)
  return self.map(l:Func).filter(function('s:_not')).first(s:NONE) is s:NONE
endfunction

function! s:_not(v) abort
  return !a:v
endfunction

function! s:Stream.none(...) abort
  let [l:Func] = s:none_args.validate(a:000)
  return self.filter(l:Func).first(s:NONE) is s:NONE
endfunction

function! s:Stream.group_by(...) abort
  let [l:Func] = s:group_by_args.validate(a:000)
  return self.to_dict(l:Func, function('s:_list'), function('s:_plus'))
endfunction

function! s:_list(v) abort
  return [a:v]
endfunction

function! s:_plus(a, b) abort
  return a:a + a:b
endfunction

function! s:Stream.to_dict(...) abort
  let [l:KeyMapper, l:ValueMapper; rest] = s:to_dict_args.validate(a:000)
  let result = {}
  if !empty(rest)
    for l:Value1 in self.to_list()
      let key = l:KeyMapper(l:Value1)
      let l:Value2 = l:ValueMapper(l:Value1)
      if has_key(result, key)
        let l:Value3 = rest[0](result[key], l:Value2)
      else
        let l:Value3 = l:Value2
      endif
      let result[key] = l:Value3
      unlet l:Value1
      unlet l:Value2
      unlet l:Value3
    endfor
  else
    for l:Value in self.to_list()
      let key = l:KeyMapper(l:Value)
      if has_key(result, key)
        throw 'vital: Stream: Stream.to_dict(): duplicated elements exist in stream '
        \   . '(key: ' . string(key . '') . ')'
      endif
      let result[key] = l:ValueMapper(l:Value)
      unlet l:Value
    endfor
  endif
  return result
endfunction

function! s:Stream.count(...) abort
  let args = s:count_args.validate(a:000)
  if self.__has_characteristic__(s:SIZED)
    if !empty(args)
      return len(filter(self.to_list(), 'args[0](v:val)'))
    else
      return len(self.to_list())
    endif
  endif
  return 1/0
endfunction

function! s:Stream.to_list() abort
  return s:_take_freeze_terminal(self, self.__estimate_size__())
endfunction

function! s:Stream.foreach(...) abort
  let [l:Func] = s:foreach_args.validate(a:000)
  let mapped = self.map(l:Func)
  call mapped.to_list()
endfunction

function! s:_is_list_of_streams(streams) abort
  return empty(filter(copy(a:streams), '!s:_is_stream(v:val)'))
endfunction

function! s:_is_stream(stream) abort
  return type(a:stream) is s:T_DICT
  \   && type(get(a:stream, '__take_possible__', 0)) is s:T_FUNC
  \   && type(get(a:stream, '__estimate_size__', 0)) is s:T_FUNC
endfunction

function! s:_validate_closed_stream(stream) abort
  call a:stream.__estimate_size__()
endfunction

function! s:_new(base, ...) abort
  let base = deepcopy(a:base)
  call map(copy(a:000), 'extend(base, deepcopy(v:val))')
  return base
endfunction

" NOTE: This requires '_upstream'.
let s:WithBuffered = {'__buffer': []}

" can use 'self.__buffer' instead of 'self._upstream.__take_possible__(n)[0]'
" after this function is invoked
function! s:WithBuffered.__read_to_buffer__(n) abort
  let open = (self._upstream.__estimate_size__() > 0)
  if len(self.__buffer) < a:n && open
    let [r, open] = s:_take_freeze_intermediate(self._upstream, a:n - len(self.__buffer))
    let self.__buffer += r
  endif
  return open || !empty(self.__buffer)
endfunction

" Safely slice if [start, end] range is narrower than [0, len - 1].
" Otherwise just return a:list (it does not copy).
" https://github.com/vim-jp/issues/issues/1049
function! s:_sublist(list, start, ...) abort
  let len = len(a:list)
  let start = min([a:start, len])
  let end = a:0 ? min([a:1, len]) : len
  return start ==# 0 && end >= len - 1 ? a:list : a:list[start : end]
endfunction

function! s:_get_non_empty_list_or_default(stream, size, default, caller) abort
  if a:stream.__estimate_size__() ==# 0
    let list = []
  else
    let list = s:_take_freeze_terminal(a:stream, a:size)
  endif
  if !empty(list)
    return list
  endif
  if a:default isnot s:NONE
    return a:default
  else
    throw 'vital: Stream: ' . a:caller .
    \     ': stream is empty and default value was not given'
  endif
endfunction

function! s:_take_freeze_intermediate(stream, size) abort
  let [list, open] = a:stream.__take_possible__(a:size)
  if !open
    call s:_freeze(a:stream, 1, 1)
  endif
  return [list, open]
endfunction

function! s:_take_freeze_terminal(stream, size) abort
  let list = a:stream.__take_possible__(a:size)[0]
  call s:_freeze(a:stream, 1/0, 0)
  return list
endfunction

function! s:_freeze(stream, depth, intermediate) abort
  if a:intermediate
    let a:stream.__take_possible__ = function('s:_throw_closed_stream_exception')
  else
    let a:stream.__estimate_size__ = function('s:_throw_closed_stream_exception')
  endif
  if has_key(a:stream, '_upstream') && a:depth > 0
    let upstreams = type(a:stream._upstream) is s:T_LIST ?
    \               a:stream._upstream : [a:stream._upstream]
    call map(copy(upstreams), 's:_freeze(v:val, a:depth - 1, a:intermediate)')
  endif
endfunction

function! s:_throw_closed_stream_exception(...) abort dict
  throw 'vital: Stream: stream has already been operated upon or closed at '
  \     . self._name
endfunction

let &cpo = s:save_cpo
unlet s:save_cpo

" vim:set et ts=2 sts=2 sw=2 tw=0:
