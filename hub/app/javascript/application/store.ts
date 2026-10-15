import { configureStore } from "@reduxjs/toolkit"
import { beforeFetch, beforeRemote, beforeVisit, rootReducer } from "@thoughtbot/superglue"

import { navigationRequest } from "@application/navigation-request"

const { pages, superglue } = rootReducer

export const store = configureStore({
  devTools: import.meta.env.DEV,
  middleware: (getDefaultMiddleware) =>
    getDefaultMiddleware({
      serializableCheck: {
        ignoredActions: [beforeFetch.type, beforeVisit.type, beforeRemote.type],
      },
    }),
  reducer: { navigationRequest: navigationRequest.reducer, pages, superglue },
})

export type AppState = ReturnType<typeof store.getState>
