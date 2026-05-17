-- 자동생성: maxapex.maxapex_batch_mapflow_oper_factor Silver (replica: 정제 passthrough, 전체교체)
{{ config(materialized='table') }}
select {{ dbt_utils.star(from=ref('stg_maxapex__maxapex_batch_mapflow_oper_factor')) }}
from {{ ref('stg_maxapex__maxapex_batch_mapflow_oper_factor') }}
