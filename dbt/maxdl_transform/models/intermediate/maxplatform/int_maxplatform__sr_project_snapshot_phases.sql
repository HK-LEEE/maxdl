-- 자동생성: maxplatform.sr_project_snapshot_phases Silver (replica: 정제 passthrough, 전체교체)
{{ config(materialized='table') }}
select {{ dbt_utils.star(from=ref('stg_maxplatform__sr_project_snapshot_phases')) }}
from {{ ref('stg_maxplatform__sr_project_snapshot_phases') }}
