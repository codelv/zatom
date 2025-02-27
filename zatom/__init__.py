import sys

def install():
    """ Install zatom as a replacement for atom"""
    sys.modules['atom'] = sys.modules['zatom']
