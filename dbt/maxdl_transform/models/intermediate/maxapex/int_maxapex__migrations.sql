-- 자동생성: maxapex.migrations Silver (replica: 정제 passthrough, 전체교체)
{{ config(materialized='table') }}
select {{ dbt_utils.star(from=ref('stg_maxapex__migrations')) }}
from {{ ref('stg_maxapex__migrations') }}
