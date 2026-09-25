docker exec -i patch01-postgres psql -U postgres -d patchdb -c \
  "SELECT product, replace(profile_id,'xccdf_org.ssgproject.content_profile_','') AS profile, rule_count
     FROM hardening_profiles WHERE product LIKE 'ol%' ORDER BY 1,2;"
