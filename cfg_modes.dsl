default_mode stop

mode "Re-Init" sequence infinite
  action init_restart "Init restart"
    init piston_retract_backup = true
    init drill_reverse = true
    init drill_move = true

    goto end_restart after 2 if drill_coupled == true and piston_coupled == true
  end

  action end_restart "End restart"
    # Set all outputs to false (safe idle)
    init drill_move = false
    init drill_reverse = false
    init piston_retract_backup = false
    init piston_push = false
    init drill_check_tx = false
    

    # Stay here forever (until operator switches mode)
    goto end_restart after 1 if time_passed >= 0
  end
endmode

mode "Empty Buffer Vault" sequence infinite
  action wip_dont_use "Burning trash" #Start Burning
  

    goto empty_done after 1 if buff_chest_full == false
  end

  action empty_done "Done!" # Infinite end cycle
    goto empty_done after 10 if time_passed >= 0
  end
endmode

mode "Auto Forward" sequence infinite
  action action_main_move "Main move"
    # Make sure other outputs are not fighting the move
    init piston_retract_backup = false
    init piston_push = false

    # piston_push = True -> causes the PC restart (contr move)
    init piston_push = true
    goto action_in_move_main after 1 if time_passed >= 0
  end

  action action_in_move_main "In move"
    init piston_push = false
    # After 1 sec: if piston coupled is TRUE -> go to same action (your rule)
    goto action_main_move after 0 if piston_coupled == true

    # After 10 sec: if piston coupled is FALSE -> retract
    goto action_retract after 10 if piston_coupled == false
  end

  action action_retract "Retract"
    init piston_push = false
    init piston_retract_backup = true

    goto action_main_move after 1 if piston_coupled == true
  end
endmode

mode "Auto Drill" sequence infinite
  action action_init_drill_move "Init move"
    # Make sure other outputs are not fighting the move
    init drill_reverse  = false
    init drill_check_tx = false
    #init drill_check_rx = false
    init drill_coupled  = false

    # This output causes the PC restart (your note)
    init drill_move = true
    goto action_drilling after 2 if drill_coupled == false
  end

  #Damn long action, should be restart proof
  action action_drilling "Boring..."
    init drill_reverse  = false
    init drill_move = true
    init drill_check_tx = true
    
    # IF reach bedrock -> go_home
    goto action_drill_homing after 1 if drill_check_rx == true
  end

  action action_drill_homing "Drill returning..."
    init drill_move = true
    init drill_reverse = true
    init drill_check_tx = true

    goto action_drill_done after 5 if drill_check_rx == true and drill_coupled == true
  end

  action action_drill_done "Done!"
    # Clear output
    init drill_move  = false
    init drill_reverse  = false
    init drill_check_tx = false
    #init drill_check_rx = false
    init drill_coupled  = false

    #Infinite done loop
    goto action_drill_done after 10 if time_passed >= 0
  end
endmode

# ===========================================================

mode "Full Auto Quarry" sequence infinite
  action action_init_drill_move "Init move"
    #Addithiona clear state
    init piston_retract_backup = false 
    #init burn_trash = false #btw useless

    # Make sure other outputs are not fighting the move
    init drill_reverse  = false
    init drill_check_tx = false
    #init drill_check_rx = false
    init drill_coupled  = false

    # This output causes the PC restart (your note)
    init drill_move = true
    goto action_drilling after 2 if drill_coupled == false and piston_coupled == true

    #In case somethink broke on restart
    goto backup_piston after 10 if piston_coupled == false
  end

  #Damn long action, should be restart proof
  action action_drilling "Boring..."
    init drill_reverse  = false
    init drill_move = true
    init drill_check_tx = true
    
    # IF reach bedrock -> go_home
    goto action_drill_homing after 2 if drill_check_rx == true
  end

  action action_drill_homing "Drill returning..."
    init drill_move = true
    init drill_reverse = true
    init drill_check_tx = true

    goto action_drill_done after 2 if drill_check_rx == true and drill_coupled == true
  end

  action action_drill_done "Done!"
    # Clear output
    init drill_move     = false
    init drill_reverse  = false
    init drill_check_tx = false
    #init drill_check_rx = false
    init drill_coupled  = false

    #goto to move forward sequence
    goto wait_item_moved after 1 if drill_coupled == true

    #go again try to retract drill
    goto action_drill_homing after 1 if drill_coupled == false
  end

  action backup_piston "Error, auto fix..."
    #return pistone to home
    init piston_retract_backup = true

    #return drill to home
    init drill_reverse = true
    init drill_move = true

    #goto drill-init in case we catch error on drill init
    goto action_init_drill_move after 10 if piston_coupled == true and drill_coupled == true
  end
  #=======================================================================
  # Check if items moving_done

  action wait_item_moved "Moving items..."
    # no init needed
    goto action_main_move after 2 if drill_itemvault_isfree == false
  end
  
  #=======================================================================
  # Moving sequence
  action action_main_move "Main move"
    # Make sure other outputs are not fighting the move
    init piston_retract_backup = false
    init piston_push = false

    # piston_push = True -> causes the PC restart (contr move)
    init piston_push = true

    #go next stage only if drill not crashed with server restart
    goto action_in_move_main after 1 if drill_coupled == true

    #go again try to retract drill
    goto action_drill_homing after 1 if drill_coupled == false
  end

  action action_in_move_main "In move"
    init piston_push = false
    # After 1 sec: if piston coupled is TRUE -> go to same action (your rule)
    goto moving_done after 1 if piston_coupled == true

    # After 10 sec: if piston coupled is FALSE -> retract
    goto action_retract after 10 if piston_coupled == false
  end

  action action_retract "Retract"
    init piston_push = false
    init piston_retract_backup = true

    goto moving_done after 1 if piston_coupled == true
  end


  action moving_done "Done move"
    # Clear output for move
    init drill_move     = false
    init drill_reverse  = false
    init drill_check_tx = false
    #init drill_check_rx = false
    init drill_coupled  = false

    # Clear output for drill
    init drill_move  = false
    init drill_reverse  = false
    init drill_check_tx = false
    #init drill_check_rx = false
    init drill_coupled  = false

    # Just a plug for sequence protecthion
    goto action_init_drill_move after 1 if time_passed >= 0
  end
endmode
