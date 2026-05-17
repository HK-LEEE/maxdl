-- 자동생성: maxplatform.casual_task_permissions Silver (replica: 정제 passthrough, 전체교체)
{{ config(materialized='table') }}
select {{ dbt_utils.star(from=ref('stg_maxplatform__casual_task_permissions')) }}
from {{ ref('stg_maxplatform__casual_task_permissions') }}
