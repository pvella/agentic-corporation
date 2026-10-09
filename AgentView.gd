## Render node for one Agent. The Agent itself (a CharacterBody2D) lives in a
## hidden layer in flat world coordinates, where it navigates; this node sits
## in the y-sorted render layer at the agent's projected feet, so people are
## depth-sorted with furniture and walls, and it draws the character upright
## (billboarded). It also carries the agent's name pill, speech bubble and
## click area, so picking happens where the character is drawn.
extends Node2D

var agent: Node = null


func _draw() -> void:
	if is_instance_valid(agent):
		agent.paint(self)
