import { createSlice } from "@reduxjs/toolkit"
import type { PayloadAction } from "@reduxjs/toolkit"

export const navigationRequest = createSlice({
  name: "navigationRequest",
  initialState: {
    id: 0,
    path: null as string | null,
  },
  reducers: {
    started(state, action: PayloadAction<{ id: number; path: string }>) {
      state.id = action.payload.id
      state.path = action.payload.path
    },
    finished(state, action: PayloadAction<{ id: number }>) {
      if (state.id === action.payload.id) {
        state.path = null
      }
    },
  },
})
