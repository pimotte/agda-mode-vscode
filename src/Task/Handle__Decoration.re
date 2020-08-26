module Impl = (Editor: Sig.Editor) => {
  module State = State.Impl(Editor);
  module Task = Task.Impl(Editor);
  module Decoration = Decoration.Impl(Editor);
  open! Task;
  open Belt;

  // from Decoration to Tasks
  let handle =
    fun
    | Decoration.AddDirectly(highlightings) => [
        WithState(
          state => {state.decorations->Decoration.addDirectly(highlightings)},
        ),
      ]
    | AddIndirectly(filepath) => [
        WithState(
          state => {state.decorations->Decoration.addIndirectly(filepath)},
        ),
      ]
    | Apply => [
        WithStateP(
          state => {
            Decoration.readTempFiles(state.decorations)
            ->Promise.map(() => {
                Decoration.applyHighlightings(
                  state.decorations,
                  state.editor,
                );
                [];
              })
          },
        ),
      ]
    | RemoveAll => [
        WithState(state => Decoration.destroy(state.decorations)),
      ]
    | Refresh => [
        WithState(
          state => {
            // highlightings
            Decoration.refresh(state.editor, state.decorations);
            // goal decorations
            state.goals
            ->Array.forEach(goal =>
                goal->Goal.refreshDecoration(state.editor)
              );
          },
        ),
      ];
};
