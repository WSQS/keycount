extends SceneTree

func _init() -> void:
	var hits := []
	for p in ProjectSettings.get_property_list():
		var n: String = p.get("name", "")
		if n.contains("focus") or n.contains("window/size"):
			hits.append("%-52s default=%s" % [n, str(ProjectSettings.get_setting(n))])
	hits.sort()
	for h in hits:
		print(h)
	print("---- 共 %d 条 ----" % hits.size())
	quit()
