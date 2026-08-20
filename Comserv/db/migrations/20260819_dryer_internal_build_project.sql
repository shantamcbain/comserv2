-- SUPERSEDED 2026-08-19.
-- Do NOT run this file against Ency.
-- v0.1 used invented project ids / record_id 99001 and was applied (if at all)
-- against the wrong database. Live rows were created via /api/project/create:
--   parent  #272 DRYER-INT  (parent_id=206 3DPRINT)
--   phases  #273 DRYER-P0 .. #279 DRYER-P6
--   todos   #2162-#2189 on those phases; INV-R1 #2190 on #207
-- Plan: /Documentation/DryerProjectImportPlan
-- This file is kept only so git history explains the v0.1 mistake.
SELECT 'DO NOT RUN — DRYER-INT is project 272 via API' AS notice;
