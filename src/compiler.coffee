[NOUN, VERB, ADVERB, CONJUNCTION] = [1..4]

exec = (aplCode, opts = {}) ->
  ast = parse aplCode, opts
  code = compileAST ast, opts
  env = [prelude.env[0][..]]
  for k, v of ast.vars then env[0][v.slot] = opts.ctx[k]
  result = vm {code, env}
  for k, v of ast.vars
    x = opts.ctx[k] = env[0][v.slot]
    if v.category is ADVERB then x.isAdverb = true
    if v.category is CONJUNCTION then x.isConjunction = true
  result

repr = (x) ->
  if x is null or typeof x in ['string', 'number', 'boolean'] then JSON.stringify x
  else if x instanceof Array then "[#{(for y in x then repr y).join ','}]"
  else if x.repr then x.repr()
  else "{#{(for k, v of x then "#{repr k}:#{repr v}").join ','}}"

compileAST = (ast, opts = {}) ->
  ast.scopeDepth = 0
  ast.nSlots = prelude.nSlots
  ast.vars = Object.create prelude.vars
  opts.ctx ?= Object.create vocabulary
  for key, value of opts.ctx when !ast.vars[key]
    ast.vars[key] = varInfo = category: NOUN, slot: ast.nSlots++, scopeDepth: ast.scopeDepth
    if typeof value is 'function' or value instanceof Proc
      varInfo.category = if value.isAdverb then ADVERB else if value.isConjunction then CONJUNCTION else VERB
      if /^[gs]et_.*/.test key then ast.vars[key[4..]] = category: NOUN

  err = (node, message) ->
    syntaxError message, file: opts.file, offset: node.offset, aplCode: opts.aplCode

  assert VERB < ADVERB < CONJUNCTION # we are relying on this ordering below
  (categorizeLambdas = (node) ->
    switch node[0]
      when 'B', ':', '←', '[', '{', '.', '⍬'
        r = VERB
        for i in [1...node.length] by 1 when node[i] then r = Math.max r, categorizeLambdas node[i]
        if node[0] is '{' then (node.category = r; VERB) else r
      when 'S', 'N', 'J' then 0
      when 'X'
        switch node[1]
          when '⍺⍺', '⍶', '∇∇' then ADVERB
          when '⍵⍵', '⍹' then CONJUNCTION
          else VERB
      else assert 0
  ) ast

  queue = [ast] # accumulates "body" nodes which we encounter on our way
  while queue.length
    {vars} = scopeNode = queue.shift()

    visit = (node) ->
      node.scopeNode = scopeNode
      switch node[0]
        when ':' then r = visit node[1]; visit node[2]; r
        when '←' then visitLHS node[1], visit node[2]
        when 'X'
          name = node[1]
          if (v = vars["get_#{name}"])?.category is VERB
            NOUN
          else
            # x ⋄ x←0 !!! VALUE ERROR
            vars[name]?.category or
              valueError "Symbol '#{name}' is referenced before assignment.",
                file: opts.file, offset: node.offset, aplCode: opts.aplCode
        when '{'
          for i in [1...node.length] by 1
            queue.push extend (body = node[i]),
              scopeNode: scopeNode
              scopeDepth: d = scopeNode.scopeDepth + 1 + (node.category isnt VERB)
              nSlots: 4
              vars: v = extend Object.create(vars),
                '⍵': slot: 0, scopeDepth: d, category: NOUN
                '∇': slot: 1, scopeDepth: d, category: VERB
                '⍺': slot: 2, scopeDepth: d, category: NOUN
                # slot 3 is reserved for a "base pointer"
                '⍫':          scopeDepth: d, category: VERB
            if node.category is CONJUNCTION
              v['⍵⍵'] = v['⍹'] = slot: 0, scopeDepth: d - 1, category: VERB
              v['∇∇'] =          slot: 1, scopeDepth: d - 1, category: CONJUNCTION
              v['⍺⍺'] = v['⍶'] = slot: 2, scopeDepth: d - 1, category: VERB
            else if node.category is ADVERB
              v['⍺⍺'] = v['⍶'] = slot: 0, scopeDepth: d - 1, category: VERB
              v['∇∇'] =          slot: 1, scopeDepth: d - 1, category: ADVERB
          node.category ? VERB
        when 'S', 'N', 'J', '⍬' then NOUN
        when '['
          for i in [2...node.length] by 1 when node[i] and visit(node[i]) isnt NOUN then err node, 'Indices must be nouns.'
          visit node[1]
        when '.'
          a = node[1..]
          h = Array a.length
          for i in [a.length - 1..0] by -1 then h[i] = visit a[i]
          # Form vectors from sequences of data
          i = 0
          while i < a.length - 1
            if h[i] is h[i + 1] is NOUN
              j = i + 2
              while j < a.length and h[j] is NOUN then j++
              a[i...j] = [['V'].concat a[i...j]]
              h[i...j] = NOUN
            else
              i++
          # Apply conjunctions and postfix adverbs
          # ⌽¨⍣3⊢(1 2)3(4 5 6) ←→ (2 1)3(6 5 4)
          i = 0
          while i < a.length
            if h[i] is VERB and i + 1 < a.length and h[i + 1] is ADVERB
              a[i...i + 2] = [['A'].concat a[i...i + 2]]
              h[i...i + 2] = VERB
            else if h[i] in [NOUN, VERB, CONJUNCTION] and i + 2 < a.length and h[i + 1] is CONJUNCTION and h[i + 2] in [NOUN, VERB]
              # allow conjunction-conjunction-something to accommodate ∘.f syntax
              a[i...i + 3] = [['C'].concat a[i...i + 3]]
              h[i...i + 3] = VERB
            else
              i++
          # Hooks
          if h.length is 2 and h[0] isnt NOUN and h[1] isnt NOUN
            a = [['H'].concat a]
            h = [VERB]
          # Forks
          if h.length >= 3 and h.length % 2 is 1 and all(for x in h then x isnt NOUN)
            a = [['F'].concat a]
            h = [VERB]
          if h[h.length - 1] isnt NOUN
            if h.length > 1 then err a[h.length - 1], 'Trailing function in expression'
          else
            # Apply monadic and dyadic functions
            while h.length > 1
              if h.length is 2 or h[h.length - 3] isnt NOUN
                a[-2..] = [['M'].concat a[-2..]]
                h[-2..] = NOUN
              else
                a[-3..] = [['D'].concat a[-3..]]
                h[-3..] = NOUN
          node[..] = a[0]
          extend node, a[0]
          h[0]
        else
          assert 0

    visitLHS = (node, rhsCategory) ->
      node.scopeNode = scopeNode
      switch node[0]
        when 'X'
          name = node[1]
          if name in '∇⍫' then err node, "Assignment to #{name} is not allowed."
          if vars[name]
            if vars[name].category isnt rhsCategory
              err node, "Inconsistent usage of symbol '#{name}', it is assigned both nouns and verbs."
          else
            vars[name] = scopeDepth: scopeNode.scopeDepth, slot: scopeNode.nSlots++, category: rhsCategory
        when '.'
          rhsCategory is NOUN or err node, 'Strand assignment can be used only for nouns.'
          for i in [1...node.length] by 1 then visitLHS node[i], rhsCategory
        when '['
          rhsCategory is NOUN or err node, 'Index assignment can be used only for nouns.'
          visitLHS node[1], rhsCategory
          for i in [2...node.length] by 1 when c = node[i] then visit c
        else
          err node, "Invalid LHS node type: #{JSON.stringify node[0]}"
      rhsCategory

    for i in [1...scopeNode.length] by 1 then visit scopeNode[i]

  render = (node) ->
    switch node[0]
      when 'B'
        if node.length is 1
          # {}0 ←→ ⍬
          [LDC, A.zilde, RET]
        else
          a = []
          for i in [1...node.length] by 1 then a.push render(node[i])...; a.push POP
          a[a.length - 1] = RET
          a
      when ':'
        x = render node[1]
        y = render node[2]
        x.concat JEQ, y.length + 2, POP, y, RET
      when '←'
        # A←5     ←→ 5
        # A×A←2 5 ←→ 4 25
        render(node[2]).concat renderLHS node[1]
      when 'X'
        # r←3 ⋄ get_c←{2×○r} ⋄ get_S←{○r*2}
        # ... before←.01×⌊100×r c S
        # ... r←r+1
        # ... after←.01×⌊100×r c S
        # ... before after ←→ (3 18.84 28.27)(4 25.13 50.26)
        # {⍺}0 !!! VALUE ERROR
        # {x}0 ⋄ x←0 !!! VALUE ERROR
        # {⍫1⋄2}⍬ ←→ 1
        # c←{} ⋄ x←{c←⍫⋄1}⍬ ⋄ {x=1:c 2⋄x}⍬ ←→ 2
        name = node[1]
        {vars} = node.scopeNode
        if name is '⍫'
          [CON]
        else if (v = vars["get_#{name}"])?.category is VERB
          [LDC, A.zero, GET, v.scopeDepth, v.slot, MON]
        else
          v = vars[name]
          [GET, v.scopeDepth, v.slot]
      when '{'
        # {1 + 1} 1                    ←→ 2
        # {⍵=0:1 ⋄ 2×∇⍵-1} 5           ←→ 32 # two to the power of
        # {⍵<2 : 1 ⋄ (∇⍵-1)+(∇⍵-2) } 8 ←→ 34 # Fibonacci sequence
        # ⊂{⍺⍺ ⍺⍺ ⍵}'hello'            ←→ ⊂⊂'hello'
        # ⊂{⍺⍺ ⍵⍵ ⍵}⌽'hello'           ←→ ⊂'olleh'
        # ⊂{⍶⍶⍵}'hello'                ←→ ⊂⊂'hello'
        # ⊂{⍶⍹⍵}⌽'hello'               ←→ ⊂'olleh'
        # +{⍵⍶⍵}10 20 30               ←→ 20 40 60
        # f←{⍵⍶⍵} ⋄ +f 10 20 30        ←→ 20 40 60
        # twice←{⍶⍶⍵} ⋄ *twice 2       ←→ 1618.1779919126539
        # f←{-⍵;⍺×⍵} ⋄ (f 5)(3 f 5)    ←→ ¯5 15
        # f←{;} ⋄ (f 5)(3 f 5)         ←→ ⍬⍬
        # ²←{⍶⍶⍵;⍺⍶⍺⍶⍵} ⋄ *²2          ←→ 1618.1779919126539
        # ²←{⍶⍶⍵;⍺⍶⍺⍶⍵} ⋄ 3*²2         ←→ 19683
        # H←{⍵⍶⍹⍵;⍺⍶⍹⍵} ⋄ +H÷ 2        ←→ 2.5
        # H←{⍵⍶⍹⍵;⍺⍶⍹⍵} ⋄ 7 +H÷ 2      ←→ 7.5
        # {;;}                         !!!
        x = render node[1]
        lx = [LAM, x.length].concat x
        f = switch node.length
          when 2 then lx
          when 3
            y = render node[2]
            ly = [LAM, y.length].concat y
            v = node.scopeNode.vars['⍠']
            ly.concat GET, v.scopeDepth, v.slot, lx, DYA
          else err node
        if node.category isnt VERB then [LAM, f.length + 1].concat f, RET else f
      when 'S'
        #   ⍴''     ←→ ,0
        #   ⍴'x'    ←→ ⍬
        #   ⍴'xx'   ←→ ,2
        #   ⍴'a''b' ←→ ,3
        #   ⍴"a""b" ←→ ,3
        #   ⍴'a""b' ←→ ,4
        #   ⍴'''a'  ←→ ,2
        #   ⍴'a'''  ←→ ,2
        #   ''''    ←→ "'"
        #   ⍴"\f\t\n\r\u1234\xff" ←→ ,18
        #   "a      !!!
        d = node[1][0] # the delimiter: '"' or "'"
        s = node[1][1...-1].replace ///#{d + d}///g, d
        [LDC, new A s, if s.length is 1 then []]
      when 'N'
        # ∞ ←→ ¯
        # ¯∞ ←→ ¯¯
        # ¯∞j¯∞ ←→ ¯¯j¯¯
        # ∞∞ ←→ ¯ ¯
        # ∞¯ ←→ ¯ ¯
        a = for x in node[1].replace(/[¯∞]/g, '-').split /j/i
              if x is '-' then Infinity
              else if x is '--' then -Infinity
              else if x.match /^-?0x/i then parseInt x, 16
              else parseFloat x
        v = if a[1] then new Z(a[0], a[1]) else a[0]
        [LDC, new A [v], []]
      when 'J'
        # 123 + «456 + 789» ←→ 1368
        f = do Function "return function(_w,_a){return(#{node[1].replace /^«|»$/g, ''})};"
        [EMB, (_w, _a) -> aplify f _w, _a]
      when '['
        # ⍴ x[⍋x←6?40] ←→ ,6
        v = node.scopeNode.vars._index
        axes = []
        a = []
        for i in [2...node.length] by 1 when c = node[i] then axes.push i - 2; a.push render(c)...
        a.push VEC, axes.length, LDC, new A(axes), VEC, 2, GET, v.scopeDepth, v.slot
        a.push render(node[1])...
        a.push DYA
        a
      when 'V'
        fragments = for i in [1...node.length] by 1 then render node[i]
        if all(for f in fragments then f.length is 2 and f[0] is LDC)
          [LDC, new A(for f in fragments then (if (x = f[1]).isSimple() then x.unwrap() else x))]
        else
          [].concat fragments..., VEC, node.length - 1
      when '⍬' then [LDC, A.zilde]
      when 'M' then render(node[2]).concat render(node[1]), MON
      when 'A' then render(node[1]).concat render(node[2]), MON
      when 'D', 'C' then render(node[3]).concat render(node[2]), render(node[1]), DYA
      when 'H'
        v = node.scopeNode.vars._hook
        render(node[2]).concat GET, v.scopeDepth, v.slot, render(node[1]), DYA
      when 'F'
        u = node.scopeNode.vars._hook
        v = node.scopeNode.vars._fork1
        w = node.scopeNode.vars._fork2
        i = node.length - 1
        r = render node[i--]
        while i >= 2
          r = r.concat(
            GET, v.scopeDepth, v.slot, render(node[i--]), DYA,
            GET, w.scopeDepth, w.slot, render(node[i--]), DYA
          )
        if i then r.concat render(node[1]), GET, u.scopeDepth, u.slot, DYA else r
      else assert 0

  renderLHS = (node) ->
    switch node[0]
      when 'X'
        name = node[1]
        {vars} = node.scopeNode
        if (v = vars["set_#{name}"])?.category is VERB
          [GET, v.scopeDepth, v.slot, MON]
        else
          v = vars[name]
          [SET, v.scopeDepth, v.slot]
      when '.' # strand assignment
        # (a b) ← 1 2 ⋄ a           ←→ 1
        # (a b) ← 1 2 ⋄ b           ←→ 2
        # (a b) ← +                 !!!
        # (a b c) ← 3 4 5 ⋄ a b c   ←→ 3 4 5
        # (a b c) ← 6     ⋄ a b c   ←→ 6 6 6
        # (a b c) ← 7 8   ⋄ a b c   !!!
        # ((a b)c)←3(4 5) ⋄ a b c   ←→ 3 3 (4 5)
        n = node.length - 1
        a = [SPL, n]
        for i in [1...node.length] by 1 then a.push renderLHS(node[i])...; a.push POP
        a
      when '[' # index assignment
        v = node.scopeNode.vars._substitute
        axes = []
        a = []
        for i in [2...node.length] by 1 when c = node[i] then axes.push i - 2; a.push render(c)...
        a.push VEC, axes.length
        a.push render(node[1])...
        a.push LDC, new A(axes), VEC, 4, GET, v.scopeDepth, v.slot, MON
        a.push renderLHS(node[1])...
        a
      else
        assert 0

  render ast

prelude = do ->
  {code, nSlots, vars} = macro ->
    fs = macro.require 'fs'
    {parse, compileAST, repr} = macro.require "#{process.cwd()}/old-apl"
    ast = parse fs.readFileSync "#{process.cwd()}/src/prelude.apl", 'utf8'
    code = compileAST ast
    macro.jsToNode repr code: code, nSlots: ast.nSlots, vars: ast.vars
  env = [[]]
  for k, v of vars then env[0][v.slot] = vocabulary[k]
  vm {code, env}
  for k, v of vars then vocabulary[k] = env[0][v.slot]
  {nSlots, vars, env}

aplify = (x) ->
  if typeof x is 'string' then (if x.length is 1 then A.scalar x else new A x)
  else if typeof x is 'number' then A.scalar x
  else if x instanceof Array
    new A(for y in x then (y = aplify y; if ⍴⍴ y then y else y.unwrap()))
  else if x instanceof A then x
  else aplError 'Cannot aplify object ' + x
