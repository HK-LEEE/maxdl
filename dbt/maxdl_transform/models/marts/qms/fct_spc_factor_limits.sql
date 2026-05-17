-- [샘플] SPC 관리인자 관제한계 팩트 (LSL/LCL/CL/UCL/USL) — 도메인 확정 전 예시
{{ config(materialized='table') }}
select id as factor_id, plant_code, factor_code, factor_desc,
       lsl, lcl, center_value as cl, ucl, usl, unit, is_active
from {{ ref('int_maxapex__maxapex_factor') }}
where deleted_at is null
