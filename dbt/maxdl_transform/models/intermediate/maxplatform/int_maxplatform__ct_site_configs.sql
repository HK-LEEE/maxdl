-- 자동생성: maxplatform.ct_site_configs Silver (replica: 정제 passthrough, 전체교체)
{{ config(materialized='table') }}
select {{ dbt_utils.star(from=ref('stg_maxplatform__ct_site_configs')) }}
from {{ ref('stg_maxplatform__ct_site_configs') }}
