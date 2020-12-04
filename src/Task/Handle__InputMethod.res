open Belt

open! Task

module IM = {
  let deactivate = (state: State.t) => {
    if state.editorIM->EditorIM.isActivated {
      state.editorIM->EditorIM.deactivate
      list{ViewEvent(InputMethod(Deactivate))}
    } else if state.promptIM->EditorIM.isActivated {
      state.promptIM->EditorIM.deactivate
      list{ViewEvent(InputMethod(Deactivate))}
    } else {
      list{}
    }
  }
}

let handleEditorIMOutput = (state: State.t, output: EditorIM.Output.t): Promise.t<list<Task.t>> => {
  open EditorIM.Output
  let handle = kind =>
    switch kind {
    | UpdateView(sequence, translation, index) =>
      Promise.resolved(list{ViewEvent(InputMethod(Update(sequence, translation, index)))})
    | Rewrite(replacements, resolve) =>
      let document = state.editor->VSCode.TextEditor.document
      let replacements = replacements->Array.map(((interval, text)) => {
        let range = VSCode.Range.make(
          document->VSCode.TextDocument.positionAt(fst(interval)),
          document->VSCode.TextDocument.positionAt(snd(interval)),
        )
        (range, text)
      })
      Editor.Text.batchReplace(document, replacements)->Promise.map(_ => {
        resolve()
        list{}
      })
    // DispatchCommand(InputMethod(Rewrite(xs, f)))
    | Activate => Promise.resolved(list{DispatchCommand(InputMethod(Activate))})
    | Deactivate => Promise.resolved(list{ViewEvent(InputMethod(Deactivate))})
    }
  output->Array.map(handle)->Util.oneByOne->Promise.map(List.concatMany)
}

module TempPromptIM = {
  let previous = ref("")
  let current = ref("")
  let activate = (self, input) => {
    let cursorOffset = String.length(input)
    previous.contents = Js.String.substring(~from=0, ~to_=cursorOffset, input)
    EditorIM.activate(self, None, [(cursorOffset, cursorOffset)])
  }
  let change = (self, input) => {
    current.contents = input
    switch EditorIM.deviseChange(self, previous.contents, input) {
    | None => Promise.resolved([EditorIM.Output.Deactivate])
    | Some(input) => EditorIM.run(self, None, input)
    }
  }

  let insertChar = (self, char) => change(self, previous.contents ++ char)

  let handle = (state, output) => {
    open EditorIM.Output
    let handle = kind =>
      switch kind {
      | UpdateView(sequence, translation, index) => list{
          ViewEvent(InputMethod(Update(sequence, translation, index))),
        }
      | Rewrite(rewrites, f) =>
        // TODO, postpone calling f
        f()

        // iterate through an array of `rewrites`
        let replaced = ref(current.contents)
        let delta = ref(0)
        let replace = (((start, end_), t)) => {
          replaced :=
            replaced.contents->Js.String2.slice(~from=0, ~to_=delta.contents + start) ++
            t ++
            replaced.contents->Js.String2.sliceToEnd(~from=delta.contents + end_)
          delta := delta.contents + Js.String.length(t) - (end_ - start)
        }

        rewrites->Array.forEach(replace)

        list{ViewEvent(PromptIMUpdate(replaced.contents))}
      | Activate => list{DispatchCommand(InputMethod(Activate))}
      | Deactivate => IM.deactivate(state)
      }
    output->Array.map(handle)->List.concatMany
  }
}

let chooseSymbol = (state: State.t, symbol) =>
  if EditorIM.isActivated(state.editorIM) {
    EditorIM.run(state.editorIM, Some(state.editor), Candidate(ChooseSymbol(symbol)))
    ->Promise.flatMap(handleEditorIMOutput(state))
    ->Promise.map(tasks =>
      Belt.List.concat(tasks, list{WithStateP(state => IM.deactivate(state)->Promise.resolved)})
    )
  } else if EditorIM.isActivated(state.promptIM) {
    EditorIM.run(state.promptIM, None, Candidate(ChooseSymbol(symbol)))
    ->Promise.map(TempPromptIM.handle(state))
    ->Promise.map(tasks =>
      Belt.List.concat(tasks, list{WithStateP(state => IM.deactivate(state)->Promise.resolved)})
    )
  } else {
    Promise.resolved(list{})
  }

let promptChange = (state: State.t, input) => {
  // activate when the user typed a backslash "/"
  let shouldActivate = Js.String.endsWith("\\", input)

  let activatePromptIM = () => {
    // remove the ending backslash "\"
    let input = Js.String.substring(~from=0, ~to_=String.length(input) - 1, input)
    TempPromptIM.activate(state.promptIM, input)

    // update the view
    list{ViewEvent(InputMethod(Activate)), ViewEvent(PromptIMUpdate(input))}
  }

  if EditorIM.isActivated(state.editorIM) {
    if shouldActivate {
      Promise.resolved(List.concatMany([IM.deactivate(state), activatePromptIM()]))
    } else {
      Promise.resolved(list{ViewEvent(PromptIMUpdate(input))})
    }
  } else if EditorIM.isActivated(state.promptIM) {
    TempPromptIM.change(state.promptIM, input)->Promise.map(TempPromptIM.handle(state))
  } else if shouldActivate {
    Promise.resolved(activatePromptIM())
  } else {
    Promise.resolved(list{ViewEvent(PromptIMUpdate(input))})
  }
}

// from Editor Command to Tasks
let handle = x =>
  switch x {
  | Command.InputMethod.Activate => list{
      WithStateP(
        state =>
          if EditorIM.isActivated(state.editorIM) {
            // already activated, insert backslash "\" instead
            Editor.Cursor.getMany(state.editor)->Array.forEach(point =>
              Editor.Text.insert(VSCode.TextEditor.document(state.editor), point, "\\")->ignore
            )
            // deactivate
            IM.deactivate(state)->Promise.resolved
          } else {
            let document = VSCode.TextEditor.document(state.editor)
            // activated the input method with positions of cursors
            let startingRanges: array<(int, int)> =
              Editor.Selection.getMany(state.editor)->Array.map(range => (
                document->VSCode.TextDocument.offsetAt(VSCode.Range.start(range)),
                document->VSCode.TextDocument.offsetAt(VSCode.Range.end_(range)),
              ))
            EditorIM.activate(state.editorIM, Some(state.editor), startingRanges)
            Promise.resolved(list{ViewEvent(InputMethod(Activate))})
          },
      ),
    }
  | InsertChar(char) => list{
      WithStateP(
        state =>
          if EditorIM.isActivated(state.editorIM) {
            let char = Js.String.charAt(0, char)
            Editor.Cursor.getMany(state.editor)->Array.forEach(point =>
              Editor.Text.insert(VSCode.TextEditor.document(state.editor), point, char)->ignore
            )
            Promise.resolved(list{})
          } else if EditorIM.isActivated(state.promptIM) {
            TempPromptIM.insertChar(state.promptIM, char)->Promise.map(TempPromptIM.handle(state))
          } else {
            Promise.resolved(list{})
          },
      ),
    }
  // | ChooseSymbol(symbol) => list{
  //     WithStateP(
  //       state =>
  //         if EditorIM.isActivated(state.editorIM) {
  //           EditorIM.run(
  //             state.editorIM,
  //             Some(state.editor),
  //             Candidate(ChooseSymbol(symbol)),
  //           )->Promise.flatMap(handleEditorIMOutput(state))
  //         } else if EditorIM.isActivated(state.promptIM) {
  //           EditorIM.run(state.promptIM, None, Candidate(ChooseSymbol(symbol)))->Promise.map(
  //             TempPromptIM.handle(state.promptIM),
  //           )
  //         } else {
  //           Promise.resolved(list{})
  //         },
  //     ),
  //   }
  | MoveUp => list{
      WithStateP(
        state =>
          EditorIM.run(state.editorIM, Some(state.editor), Candidate(BrowseUp))->Promise.flatMap(
            handleEditorIMOutput(state),
          ),
      ),
    }
  | MoveRight => list{
      WithStateP(
        state =>
          EditorIM.run(state.editorIM, Some(state.editor), Candidate(BrowseRight))->Promise.flatMap(
            handleEditorIMOutput(state),
          ),
      ),
    }
  | MoveDown => list{
      WithStateP(
        state =>
          EditorIM.run(state.editorIM, Some(state.editor), Candidate(BrowseDown))->Promise.flatMap(
            handleEditorIMOutput(state),
          ),
      ),
    }
  | MoveLeft => list{
      WithStateP(
        state =>
          EditorIM.run(state.editorIM, Some(state.editor), Candidate(BrowseLeft))->Promise.flatMap(
            handleEditorIMOutput(state),
          ),
      ),
    }
  }
